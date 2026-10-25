import AppKit
import Foundation
import Network
import Observation
import RemoteCodeHost
import RemoteCodeKit
import Synchronization
import UserNotifications

/// The Mac app's single source of truth: owns the host runtime, the WebSocket
/// listener, the sleep assertion and everything the menu shows.
@MainActor
@Observable
final class AppController: MacStatusProviding {
    enum Phase: Equatable {
        case starting
        case running
        case failed(String)
    }

    /// A pairing QR code that is currently shown.
    struct PairingInvitation: Equatable {
        var payload: PairingPayload
        var link: String
        var image: NSImage?
        var verificationCode: String
        var devicesBefore: Set<String>
    }

    let settings = AppSettings()
    /// Finds and installs new releases from GitHub (D-105).
    @ObservationIgnored private(set) lazy var updater = AppUpdater(settings: settings)
    let lidClosed = LidClosedController()
    let sleepAssertion = SleepAssertion()

    private(set) var phase: Phase = .starting
    private(set) var macName = Host.current().localizedName ?? "Mac"
    private(set) var claude = ClaudeCLIStatus(installed: false)
    private(set) var isCheckingClaude = false
    /// Every agent CLI found on this Mac (Claude Code first).
    private(set) var agents: [AgentStatus] = []
    /// Last known usage limits, for the menu.
    private(set) var usageLimits: [UsageLimits] = []
    /// Why written weekly summaries are unavailable, if they are.
    private(set) var summaryUnavailableReason: String?
    private(set) var tailscale: TailscaleStatus = .notInstalled
    private(set) var localAddresses: [String] = []
    private(set) var port: Int?
    private(set) var devices: [PairedDevice] = []
    private(set) var connectedDeviceIds: Set<String> = []
    private(set) var sessions: [SessionSummary] = []
    private(set) var activeSessionIds: Set<String> = []
    private(set) var pendingRequests: [PermissionRequest] = []
    /// The Claude session started by the Tailscale assistant, if any.
    private(set) var tailscaleSetupSessionId: String?
    private(set) var pairing: PairingInvitation?
    private(set) var newlyPairedDevice: PairedDevice?
    private(set) var macFingerprint = ""
    private(set) var launchAtLogin = LaunchAtLogin.isEnabled
    private(set) var launchAtLoginNeedsApproval = LaunchAtLogin.requiresApproval
    private(set) var launchAtLoginError: String?
    private(set) var notificationTest: NotificationTestStatus?
    var alert: String?

    enum NotificationTestStatus: Equatable {
        case sending
        case sent(String)
        case failed(String)
    }

    @ObservationIgnored private var runtime: HostRuntime?
    @ObservationIgnored private let listener = WebSocketListener()
    @ObservationIgnored private var environment = ProcessInfo.processInfo.environment
    @ObservationIgnored private var observerTasks: [Task<Void, Never>] = []
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let macNameBox = MacNameBox()
    @ObservationIgnored private let secrets = KeychainSecretStore(service: "com.ardasenturk.Pilothouse.Mac.secrets")
    @ObservationIgnored private var started = false

    static let apiKeyAccount = "anthropic-api-key"
    static let ntfyTokenAccount = "ntfy-token"

    var pendingPermissionCount: Int { pendingRequests.count }

    var openSessions: [SessionSummary] {
        sessions.filter { $0.state != .closed }
    }

    var activeSessions: [SessionSummary] {
        sessions.filter { activeSessionIds.contains($0.id) || $0.state.isBusy }
    }

    /// Addresses phones can use, for display.
    var reachableAddresses: [HostAddress] {
        localAddresses.map { HostAddress(host: $0, kind: .local) } + tailscale.addresses
    }

    // MARK: Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        sleepAssertion.acquire()
        macNameBox.set(macName)
        updater.startAutomaticChecks()

        environment = await LoginShellEnvironment.capture()
        await refreshClaude()
        await refreshNetwork(broadcast: false)

        do {
            let identity = try KeychainIdentityStore(service: "com.ardasenturk.Pilothouse.Mac.identity" + Self.previewSuffix).loadOrCreateIdentity()
            macFingerprint = identity.fingerprint
            let nameBox = macNameBox
            let runtime = try HostRuntime(
                configuration: hostConfiguration(),
                identity: identity,
                serverVersion: AppInfo.version,
                status: self,
                macName: { nameBox.value },
                agentLauncher: { [weak self] kind in
                    guard let self else { throw ErrorPayload(code: .internalError, message: "Remote Code is shutting down.") }
                    return try await self.makeLauncher(for: kind)
                }
            )
            self.runtime = runtime
            await runtime.start()
            await configureInsights()
            let boundPort = try await listener.start(
                configuration: WebSocketListener.Configuration(
                    preferredPort: Self.isPreview ? settings.preferredPort + 1_000 : settings.preferredPort,
                    bonjourName: macName,
                    txtRecord: ["id": identity.fingerprint, "v": String(RemoteCodeProtocol.version)]
                )
            ) { transport in
                Task { await runtime.endpoint.accept(transport) }
            }
            port = boundPort
            phase = .running
            startObservers(runtime)
            await applyNotificationSettings()
            await refreshSessions()
        } catch {
            phase = .failed(String(localized: "Remote Code could not start: \(error.localizedDescription)"))
        }

        await lidClosed.apply(enabled: settings.keepAwakeWithLidClosed, pauseOnBattery: settings.pauseLidModeOnBattery)
        startNetworkMonitoring()
    }

    func shutdown() async {
        for task in observerTasks { task.cancel() }
        observerTasks.removeAll()
        pathMonitor.cancel()
        listener.stop()
        await runtime?.shutdown()
        await lidClosed.restore()
        sleepAssertion.release()
    }

    // MARK: Claude

    func refreshClaude() async {
        isCheckingClaude = true
        claude = await ClaudeLocator.status(environment: environment)
        agents = await AgentLocator.statuses(claude: claude, environment: environment, delegation: settings.delegationAgents)
        isCheckingClaude = false
        await configureInsights()
        await runtime?.sessions.updateConfiguration(hostConfiguration())
    }

    /// Re-reads which agents may be delegated to and tells the phones.
    func applyDelegationSettings() async {
        agents = agents.map { status in
            var status = status
            status.delegationEnabled = status.kind != .claude && settings.delegationAgents.contains(status.kind)
                && status.installed && status.loggedIn != false
            return status
        }
        await applySettings()
    }

    private func makeLauncher(for kind: AgentKind) async throws -> any AgentLauncher {
        if kind == .claude { return try await makeLauncher() }
        var status = agents.first { $0.kind == kind }
        if status?.path == nil {
            await refreshClaude()
            status = agents.first { $0.kind == kind }
        }
        guard let path = status?.path else {
            throw ErrorPayload(
                code: .agentNotInstalled,
                message: String(localized: "\(kind.displayName) is not installed on this Mac. Install it, sign in once in Terminal, then try again.")
            )
        }
        switch kind {
        case .codex:
            return CodexLauncher(executable: path, environment: environment)
        case .gemini:
            return GeminiLauncher(executable: path, environment: environment)
        default:
            throw ErrorPayload(code: .agentNotInstalled, message: "\(kind.displayName) is not supported by this version of Remote Code.")
        }
    }

    private func makeLauncher() async throws -> any ClaudeLauncher {
        if claude.path == nil { await refreshClaude() }
        guard let path = claude.path else {
            throw ErrorPayload(
                code: .claudeNotInstalled,
                message: String(localized: "Claude Code is not installed on this Mac. Install it, run `claude` once in Terminal to sign in, then try again.")
            )
        }
        let apiKey = settings.useAPIKey ? secrets.read(account: Self.apiKeyAccount) : nil
        return CLIClaudeLauncher(executable: path, environment: environment, apiKey: apiKey)
    }

    var hasAPIKey: Bool {
        secrets.read(account: Self.apiKeyAccount)?.isEmpty == false
    }

    func saveAPIKey(_ key: String) {
        do {
            try secrets.write(key.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.apiKeyAccount)
        } catch {
            alert = String(localized: "The API key could not be saved: \(error.localizedDescription)")
        }
    }

    // MARK: Status

    func macStatus() async -> MacStatus {
        MacStatus(
            macName: macName,
            sleepPrevented: sleepAssertion.isActive,
            lidClosedModeEnabled: lidClosed.isEffectivelyActive,
            claude: claude,
            tailscale: tailscale,
            addresses: reachableAddresses,
            port: port ?? settings.preferredPort,
            activeSessionCount: activeSessions.count,
            bypassPermissionsAllowed: settings.allowBypassPermissions,
            defaultModel: settings.defaultModel.isEmpty ? nil : settings.defaultModel,
            agents: agents
        )
    }

    func refreshNetwork(broadcast: Bool = true) async {
        let addresses = NetworkInterfaces.localAddresses()
        let tailscaleStatus = await TailscaleProbe.status(environment: environment)
        let changed = addresses != localAddresses || tailscaleStatus != tailscale
        localAddresses = addresses
        tailscale = tailscaleStatus
        if changed, broadcast, let runtime {
            // Phones store the new addresses (e.g. a freshly set-up Tailscale IP).
            await runtime.hub.post(.macStatus(await macStatus()))
        }
    }

    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in await self?.refreshNetwork() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.ardasenturk.Pilothouse.path"))
        observerTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.refreshNetwork()
            }
        })
    }

    private func startObservers(_ runtime: HostRuntime) {
        observerTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshUsageLimits()
                try? await Task.sleep(for: .seconds(300))
            }
        })
        observerTasks.append(Task { [weak self] in
            for await list in await runtime.devices.changes() {
                self?.devicesChanged(list)
            }
        })
        observerTasks.append(Task { [weak self] in
            for await notification in await runtime.hub.stream() {
                switch notification {
                case .sessionStarted, .sessionUpdated, .sessionDeleted, .sessionEnded:
                    await self?.refreshSessions()
                case .permissionRequest, .permissionResolved:
                    self?.pendingRequests = await runtime.broker.pendingRequests
                default:
                    break
                }
            }
        })
        observerTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                let connected = await runtime.endpoint.connectedDeviceIds
                self?.connectedDeviceIds = connected
                try? await Task.sleep(for: .seconds(3))
            }
        })
    }

    private func refreshSessions() async {
        guard let runtime else { return }
        sessions = await runtime.sessions.summaries()
        activeSessionIds = Set(await runtime.sessions.activeSessions().map(\.id))
    }

    private func devicesChanged(_ list: [PairedDevice]) {
        devices = list
        if let pairing, let added = list.first(where: { !pairing.devicesBefore.contains($0.id) }) {
            newlyPairedDevice = added
        }
    }

    // MARK: Pairing

    func createPairing() async {
        guard let runtime, let port else { return }
        await refreshNetwork(broadcast: false)
        let payload = await runtime.makePairingPayload(
            macName: macName, localAddresses: localAddresses, tailscale: tailscale, port: port
        )
        guard let link = payload.url?.absoluteString else { return }
        newlyPairedDevice = nil
        pairing = PairingInvitation(
            payload: payload,
            link: link,
            image: QRCode.image(for: link),
            verificationCode: KeyFingerprint.displayCode(for: runtime.identity.publicKey),
            devicesBefore: Set(devices.map(\.id))
        )
    }

    func endPairing() async {
        pairing = nil
        newlyPairedDevice = nil
        await runtime?.pairing.revokeAll()
    }

    func revoke(_ device: PairedDevice) async {
        await runtime?.devices.revoke(device.id)
    }

    // MARK: Sessions

    func close(_ session: SessionSummary) async {
        do {
            try await runtime?.sessions.close(session.id)
        } catch {
            alert = String(describing: error)
        }
    }

    /// Starts a Claude session on the Mac itself (used by the Tailscale assistant).
    func startLocalSession(cwd: String, prompt: String) async throws -> SessionSummary {
        guard let runtime else {
            throw ErrorPayload(code: .internalError, message: String(localized: "Remote Code is not running."))
        }
        return try await runtime.sessions.start(StartSession(cwd: cwd, permissionMode: .default, firstMessage: prompt))
    }

    /// Sends a follow-up message from the Mac (e.g. "I have signed in").
    func send(_ text: String, to sessionId: String) async {
        do {
            try await runtime?.sessions.send(SendMessage(sessionId: sessionId, text: text))
        } catch {
            alert = (error as? ErrorPayload)?.message ?? error.localizedDescription
        }
    }

    func interrupt(_ sessionId: String) async {
        try? await runtime?.sessions.interrupt(sessionId)
    }

    /// Live events of a session for the Mac-side monitor.
    func events(of sessionId: String) async -> AsyncStream<SequencedEvent>? {
        try? await runtime?.sessions.subscribe(sessionId, fromSeq: 1)
    }

    /// Answers a permission request from the Mac (any device may answer).
    func respond(to request: PermissionRequest, allow: Bool, remember: Bool = false) async {
        do {
            try await runtime?.broker.respond(PermissionResponse(requestId: request.id, allow: allow, remember: remember))
        } catch {
            alert = (error as? ErrorPayload)?.message ?? error.localizedDescription
        }
    }

    // MARK: Tailscale

    var tailscaleStage: TailscaleSetup.Stage {
        TailscaleSetup.stage(of: tailscale)
    }

    /// "Set up with Claude" (prompt §7.2): a Claude session in the home folder
    /// with the setup instructions; it can be followed from the phone too.
    func startTailscaleSetup() async {
        if let existing = tailscaleSetupSessionId, sessions.contains(where: { $0.id == existing && $0.state != .closed }) {
            return
        }
        do {
            let prompt = TailscaleSetup.claudePrompt(languageCode: Locale.preferredLanguages.first)
            let session = try await startLocalSession(cwd: "~", prompt: prompt)
            tailscaleSetupSessionId = session.id
        } catch {
            alert = (error as? ErrorPayload)?.message ?? error.localizedDescription
        }
    }

    /// Polls Tailscale while the assistant window is open.
    func watchTailscale() async {
        while !Task.isCancelled {
            await refreshNetwork()
            try? await Task.sleep(for: .seconds(tailscaleStage.isConnected ? 30 : 4))
        }
    }

    // MARK: Settings

    func applySettings() async {
        await runtime?.sessions.updateConfiguration(hostConfiguration())
        await configureInsights()
        await applyNotificationSettings()
        await lidClosed.apply(enabled: settings.keepAwakeWithLidClosed, pauseOnBattery: settings.pauseLidModeOnBattery)
        if let runtime { await runtime.hub.post(.macStatus(await macStatus())) }
    }

    // MARK: Insights

    /// Gives the summary service its narrator, the installed agents and the
    /// Codex limit reader (no model call, D-097).
    func configureInsights() async {
        guard let runtime else { return }
        let narrator: any WeeklyNarrator = settings.weeklySummaryEnabled ? AppleWeeklyNarrator() : DisabledNarrator()
        summaryUnavailableReason = await narrator.unavailableReason(language: nil)
        var readers: [AgentKind: @Sendable () async -> UsageLimits?] = [:]
        if let codex = agents.first(where: { $0.kind == .codex && $0.installed })?.path {
            let environment = environment
            readers[.codex] = { await CodexLimitReader.read(executable: codex, environment: environment) }
        }
        let installed = agents.filter(\.installed).map(\.kind)
        await runtime.insights.configure(narrator: narrator, agents: installed.isEmpty ? [.claude] : installed, liveReaders: readers)
    }

    func refreshUsageLimits() async {
        guard let runtime else { return }
        usageLimits = await runtime.insights.usageLimits()
    }

    // MARK: Notifications

    var ntfyConfiguration: NtfyConfiguration? {
        NtfyConfiguration(server: settings.ntfyServer, topic: settings.ntfyTopic, token: secrets.read(account: Self.ntfyTokenAccount))
    }

    var hasNtfyToken: Bool {
        secrets.read(account: Self.ntfyTokenAccount)?.isEmpty == false
    }

    /// Stores the ntfy access token in the Keychain; an empty token removes it.
    func saveNtfyToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try secrets.write(trimmed.isEmpty ? nil : trimmed, account: Self.ntfyTokenAccount)
        } catch {
            alert = String(localized: "The access token could not be saved: \(error.localizedDescription)")
        }
        Task { await applyNotificationSettings() }
    }

    func regenerateNtfyTopic() {
        settings.ntfyTopic = NtfyConfiguration.randomTopic()
        Task { await applyNotificationSettings() }
    }

    /// Hands the current preferences and destinations to the host (D-095).
    func applyNotificationSettings() async {
        guard let runtime else { return }
        var sinks: [any AlertSink] = []
        if settings.notificationsEnabled, settings.notifyOnMac, await MacNotificationSink.requestAuthorization() {
            sinks.append(MacNotificationSink())
        }
        if settings.notifyViaNtfy, let configuration = ntfyConfiguration {
            sinks.append(NtfyPublisher(configuration: configuration, macId: macFingerprint, format: AlertText.ntfyContent))
        }
        await runtime.notifications.configure(
            NotificationPreferences(
                enabled: settings.notificationsEnabled,
                kinds: settings.notificationKinds,
                includeDetail: settings.notificationIncludesSummary
            ),
            sinks: sinks
        )
    }

    /// Sends a sample notification to every enabled destination.
    func sendTestNotification() async {
        notificationTest = .sending
        let headline = String(localized: "Test notification from \(macName)")
        let detail = String(localized: "Notifications from Remote Code arrive like this.")
        var results: [String] = []
        if settings.notifyOnMac {
            if await MacNotificationSink.requestAuthorization() {
                let content = UNMutableNotificationContent()
                content.title = headline
                content.body = detail
                content.sound = .default
                do {
                    try await MacNotificationSink().deliver(content)
                    results.append(String(localized: "Mac: shown"))
                } catch {
                    results.append(String(localized: "Mac: \(error.localizedDescription)"))
                }
            } else {
                results.append(String(localized: "Mac: notifications are turned off in System Settings"))
            }
        }
        if settings.notifyViaNtfy {
            guard let configuration = ntfyConfiguration else {
                notificationTest = .failed(String(localized: "Enter a valid server address (https://…)."))
                return
            }
            do {
                let status = try await NtfyPublisher(configuration: configuration).publish(
                    NtfyMessage(topic: configuration.topic, title: "Remote Code", message: "\(headline)\n\(detail)", tags: ["bell"])
                )
                results.append(String(localized: "ntfy: delivered (HTTP \(status))"))
            } catch {
                notificationTest = .failed(String(localized: "ntfy: \(String(describing: error))"))
                return
            }
        }
        notificationTest = results.isEmpty
            ? .failed(String(localized: "Turn on at least one destination."))
            : .sent(results.joined(separator: " · "))
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        // Shown in Settings: the menu's alert is not visible from there.
        launchAtLoginError = nil
        do {
            try LaunchAtLogin.setEnabled(enabled)
        } catch {
            launchAtLoginError = String(localized: "Could not change the login item: \(error.localizedDescription)")
        }
        refreshLaunchAtLogin()
    }

    /// Re-reads the login item, which can change in System Settings or be
    /// unknown when the app is opened right at login.
    func refreshLaunchAtLogin() {
        launchAtLogin = LaunchAtLogin.isEnabled
        launchAtLoginNeedsApproval = LaunchAtLogin.requiresApproval
    }

    /// Debug builds started with `REMOTECODE_PREVIEW=1` run beside the installed
    /// app for UI work: their own data folder, Keychain identity and port.
    static let isPreview: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["REMOTECODE_PREVIEW"] == "1"
        #else
        false
        #endif
    }()

    static var previewSuffix: String { isPreview ? ".preview" : "" }

    private func hostConfiguration() -> HostConfiguration {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return HostConfiguration(
            homeDirectory: NSHomeDirectory(),
            dataDirectory: support.appendingPathComponent("Pilothouse" + Self.previewSuffix, isDirectory: true),
            retentionDays: settings.retentionDays,
            allowBypassPermissions: settings.allowBypassPermissions,
            defaultModel: settings.defaultModel.isEmpty ? nil : settings.defaultModel,
            defaultPermissionMode: settings.defaultPermissionMode,
            delegationAgents: agents.filter(\.delegationEnabled).map(\.kind)
        )
    }
}

/// Thread-safe holder for the Mac name, read from the connection actors.
final class MacNameBox: Sendable {
    private let storage = Mutex("Mac")
    var value: String { storage.withLock { $0 } }
    func set(_ name: String) { storage.withLock { $0 = name } }
}

/// Used when written summaries are turned off in Settings.
private struct DisabledNarrator: WeeklyNarrator {
    func unavailableReason(language: String?) async -> String? {
        let bundle = AppleWeeklyNarrator.bundle(for: language)
        return String(localized: "Written summaries are turned off in Remote Code settings on your Mac.", bundle: bundle)
    }

    func narrate(
        _ summary: WeeklySummary, digests: [ProjectDigest], language: String?
    ) async throws -> (WeeklyNarrative, [String: [String]]) {
        throw AppleWeeklyNarrator.NarratorError.unavailable
    }
}
