import Foundation
import PilothouseHost
import PilothouseKit

/// The headless counterpart of the Mac app's `AppController` (D-110): owns the
/// host runtime, the WebSocket listener, the control channel and what the
/// phones see as "the Mac".
actor LinuxHost: MacStatusProviding {
    static let version = "1.1.2"
    static var serverVersion: String { "\(version) (Linux)" }

    /// Interfaces of containers, bridges and VMs: never reachable from a phone.
    static let virtualInterfacePrefixes = ["docker", "br-", "veth", "virbr", "cni", "flannel", "cali", "vxlan", "lxc", "lxd", "podman", "tailscale", "wg"]

    let options: ServerOptions
    private var environment: [String: String] = ProcessInfo.processInfo.environment
    private var claude = ClaudeCLIStatus(installed: false)
    private var agents: [AgentStatus] = []
    private var tailscale: TailscaleStatus = .notInstalled
    private var localAddresses: [String] = []
    private var runtime: HostRuntime?
    private var listener: POSIXWebSocketListener?
    private var control: ControlServer?
    private var tasks: [Task<Void, Never>] = []

    init(options: ServerOptions) {
        self.options = options
    }

    // MARK: Lifecycle

    func start() async throws {
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/bash"
        let loginShell = await LoginShellEnvironment.capture(shell: shell, home: options.homeDirectory)
        environment = Self.childEnvironment(process: ProcessInfo.processInfo.environment, loginShell: loginShell, shell: shell)
        await refreshAgents()
        await refreshNetwork(broadcast: false)

        let identity = try FileIdentityStore(url: options.identityURL).loadOrCreateIdentity()
        let name = options.name
        let runtime = try HostRuntime(
            configuration: hostConfiguration(),
            identity: identity,
            serverVersion: Self.serverVersion,
            status: self,
            macName: { name },
            agentLauncher: { [weak self] kind in
                guard let self else { throw ErrorPayload(code: .internalError, message: "Pilothouse is shutting down.") }
                return try await self.makeLauncher(for: kind)
            }
        )
        self.runtime = runtime
        await runtime.start()
        await configureInsights()
        await configureNotifications()
        listener = try POSIXWebSocketListener(preferredPort: options.port, portSearchRange: options.portSearchRange) { transport in
            Task { await runtime.endpoint.accept(transport) }
        }
        control = try ControlServer(host: self, url: options.controlURL)
        startObservers(runtime)
        await printBanner(identity: identity)
    }

    func shutdown() async {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        listener?.stop()
        control?.stop()
        await runtime?.shutdown()
    }

    private func startObservers(_ runtime: HostRuntime) {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.refreshNetwork(broadcast: true)
            }
        })
        tasks.append(Task { [weak self] in
            // Asking the CLIs starts processes; do it every half hour, or every
            // minute until Claude is signed in (so the phone sees the sign-in).
            var minutes = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                minutes += 1
                guard let self else { return }
                let signedIn = await self.claudeSignedIn
                if minutes >= 30 || !signedIn {
                    minutes = 0
                    await self.refreshAgents(broadcast: true)
                }
            }
        })
        tasks.append(Task {
            for await notification in await runtime.hub.stream() {
                if case .permissionRequest(let request) = notification {
                    Console.log("Waiting for approval: \(request.tool) in session \(request.sessionId.prefix(8))")
                }
            }
        })
    }

    /// What the agent CLIs see: the container's environment (Compose's
    /// `environment:`, e.g. `CLAUDE_CODE_OAUTH_TOKEN`) with the login shell's on
    /// top, minus Pilothouse's own secrets. Unlike the Mac app, which is started
    /// by launchd, the server's own environment is the user's intent.
    static func childEnvironment(process: [String: String], loginShell: [String: String], shell: String) -> [String: String] {
        var environment = process.merging(loginShell) { _, shellValue in shellValue }
        for key in ["PILOTHOUSE_ANTHROPIC_API_KEY", "PILOTHOUSE_NTFY_TOKEN"] {
            environment.removeValue(forKey: key)
        }
        environment["SHELL"] = environment["SHELL"] ?? shell
        return environment
    }

    private func printBanner(identity: IdentityKeyPair) async {
        let devices = await runtime?.devices.all ?? []
        var lines = [
            "Pilothouse \(Self.serverVersion) is running as “\(options.name)”.",
            "  Port:       \(listener?.port ?? options.port)",
            "  Addresses:  \(reachableAddresses.map(\.host).joined(separator: ", ").ifEmpty("none found — set PILOTHOUSE_ADDRESSES"))",
            "  Claude:     \(Self.describe(claude))",
            "  Home:       \(options.homeDirectory)",
            "  Data:       \(options.dataDirectory.path)",
            "  Paired:     \(devices.count) device(s)",
        ]
        for agent in agents where agent.kind != .claude && agent.installed {
            lines.append("  \(agent.kind.displayName): \(agent.version ?? "installed")\(agent.loggedIn == false ? ", not signed in" : "")")
        }
        if claude.installed, claude.loggedIn == false {
            lines.append("")
            lines.append("Claude Code is not signed in yet. Run once:  docker exec -it pilothouse claude")
        }
        if devices.isEmpty {
            lines.append("")
            lines.append("Pair your iPhone or iPad:  docker exec -it pilothouse pilothouse-server pair")
        }
        Console.log(lines.joined(separator: "\n"))
    }

    static func describe(_ claude: ClaudeCLIStatus) -> String {
        guard claude.installed else { return "not installed" }
        let signIn = switch claude.loggedIn {
        case true?: "signed in"
        case false?: "NOT signed in"
        case nil: "sign-in unknown"
        }
        return "\(claude.version ?? "installed") — \(signIn)"
    }

    // MARK: Agents

    var claudeSignedIn: Bool { claude.installed && claude.loggedIn != false }

    func refreshAgents(broadcast: Bool = false) async {
        let previous = (claude, agents)
        claude = await ClaudeLocator.status(environment: environment, home: options.homeDirectory)
        agents = await AgentLocator.statuses(
            claude: claude, environment: environment, delegation: options.delegationAgents, home: options.homeDirectory
        )
        guard let runtime else { return }
        await runtime.sessions.updateConfiguration(hostConfiguration())
        if previous.0 != claude || previous.1 != agents {
            await configureInsights()
            if broadcast { await runtime.hub.post(.macStatus(await macStatus())) }
        }
    }

    private func makeLauncher(for kind: AgentKind) async throws -> any AgentLauncher {
        var status = agents.first { $0.kind == kind }
        if status?.path == nil || (kind == .claude && claude.loggedIn == false) {
            await refreshAgents(broadcast: true)
            status = agents.first { $0.kind == kind }
        }
        guard let path = kind == .claude ? claude.path : status?.path else {
            throw ErrorPayload(
                code: kind == .claude ? .claudeNotInstalled : .agentNotInstalled,
                message: "\(kind.displayName) is not installed on \(options.name). Install it in the container and sign in once with `docker exec -it pilothouse \(kind.executableName)`."
            )
        }
        switch kind {
        case .claude:
            return CLIClaudeLauncher(executable: path, environment: environment, apiKey: options.anthropicAPIKey)
        case .codex:
            return CodexLauncher(executable: path, environment: environment)
        case .gemini:
            return GeminiLauncher(executable: path, environment: environment)
        default:
            throw ErrorPayload(code: .agentNotInstalled, message: "\(kind.displayName) is not supported by this version of Pilothouse.")
        }
    }

    private func hostConfiguration() -> HostConfiguration {
        options.hostConfiguration(delegation: agents.filter(\.delegationEnabled).map(\.kind))
    }

    private func configureInsights() async {
        guard let runtime else { return }
        var readers: [AgentKind: @Sendable () async -> UsageLimits?] = [:]
        if let codex = agents.first(where: { $0.kind == .codex && $0.installed })?.path {
            let environment = environment
            readers[.codex] = { await CodexLimitReader.read(executable: codex, environment: environment) }
        }
        let installed = agents.filter(\.installed).map(\.kind)
        await runtime.insights.configure(
            narrator: UnavailableNarrator(), agents: installed.isEmpty ? [.claude] : installed, liveReaders: readers
        )
    }

    private func configureNotifications() async {
        guard let runtime else { return }
        var sinks: [any AlertSink] = []
        if let ntfy = options.ntfy {
            sinks.append(NtfyPublisher(configuration: ntfy, macId: runtime.identity.fingerprint))
        }
        await runtime.notifications.configure(
            NotificationPreferences(enabled: !sinks.isEmpty, kinds: options.notificationKinds, includeDetail: options.notificationIncludesDetail),
            sinks: sinks
        )
    }

    // MARK: Network

    func refreshNetwork(broadcast: Bool) async {
        let addresses = options.advertisedAddresses.isEmpty ? Self.detectedLANAddresses() : options.advertisedAddresses
        var status = await TailscaleProbe.status(environment: environment)
        if !status.running, let address = options.tailscaleAddress ?? Self.detectedTailscaleAddress() {
            // Tailscale runs on the host; its CLI is not inside the container.
            status = TailscaleStatus(
                installed: true, running: true, backendState: "Running", ipv4: address,
                magicDNSName: options.magicDNSName, magicDNSEnabled: options.magicDNSName != nil
            )
        }
        let changed = addresses != localAddresses || status != tailscale
        localAddresses = addresses
        tailscale = status
        if changed, broadcast, let runtime {
            Console.log("Addresses changed: \(reachableAddresses.map(\.host).joined(separator: ", "))")
            await runtime.hub.post(.macStatus(await macStatus()))
        }
    }

    static func detectedLANAddresses() -> [String] {
        var seen = Set<String>()
        return NetworkInterfaces.ipv4()
            .filter { interface in !virtualInterfacePrefixes.contains { interface.name.hasPrefix($0) } }
            .map(\.address)
            .filter { HostAddress.classify($0) == .local && seen.insert($0).inserted }
    }

    static func detectedTailscaleAddress() -> String? {
        NetworkInterfaces.ipv4().first { HostAddress.classify($0.address) == .tailscale }?.address
    }

    var reachableAddresses: [HostAddress] {
        localAddresses.map { HostAddress(host: $0, kind: .local) } + tailscale.addresses
    }

    // MARK: MacStatusProviding

    func macStatus() async -> MacStatus {
        let active = await runtime?.sessions.activeSessions().count ?? 0
        return MacStatus(
            macName: options.name,
            // A Raspberry Pi or server does not sleep; nothing to keep awake.
            sleepPrevented: true,
            lidClosedModeEnabled: false,
            claude: claude,
            tailscale: tailscale,
            addresses: reachableAddresses,
            port: listener?.port ?? options.port,
            activeSessionCount: active,
            bypassPermissionsAllowed: options.allowBypassPermissions,
            defaultModel: options.defaultModel,
            agents: agents
        )
    }

    // MARK: Control channel

    func pairingInvitation() async throws -> ControlPairing {
        guard let runtime, let listener else { throw OptionError("The host is not running.") }
        await refreshNetwork(broadcast: true)
        let payload = await runtime.makePairingPayload(
            macName: options.name, localAddresses: localAddresses, tailscale: tailscale, port: listener.port
        )
        guard let link = payload.url?.absoluteString else { throw OptionError("The pairing link could not be built.") }
        return ControlPairing(
            link: link,
            verificationCode: KeyFingerprint.displayCode(for: runtime.identity.publicKey),
            expiresAt: payload.exp,
            addresses: payload.addresses.map(\.host),
            port: listener.port
        )
    }

    func controlStatus() async -> ControlStatus {
        await refreshAgents(broadcast: true)
        await refreshNetwork(broadcast: true)
        let connected = await runtime?.endpoint.connectedDeviceIds ?? []
        let devices = await runtime?.devices.all ?? []
        let sessions = await runtime?.sessions.summaries() ?? []
        return ControlStatus(
            name: options.name,
            version: Self.serverVersion,
            protocolVersion: PilothouseProtocol.version,
            fingerprint: runtime?.identity.fingerprint ?? "",
            port: listener?.port ?? options.port,
            addresses: reachableAddresses.map(\.host),
            homeDirectory: options.homeDirectory,
            claude: Self.describe(claude),
            agents: agents.map { agent in
                ControlStatus.Agent(
                    name: agent.kind.displayName, installed: agent.installed, version: agent.version,
                    loggedIn: agent.loggedIn, delegation: agent.delegationEnabled
                )
            },
            pairedDevices: devices.count,
            connectedDevices: connected.count,
            sessions: sessions.count,
            activeSessions: await runtime?.sessions.activeSessions().count ?? 0,
            bypassPermissionsAllowed: options.allowBypassPermissions,
            ntfy: options.ntfy != nil
        )
    }

    func controlDevices() async -> [ControlDevice] {
        let connected = await runtime?.endpoint.connectedDeviceIds ?? []
        return (await runtime?.devices.all ?? []).map { device in
            ControlDevice(
                id: device.id, name: device.name, platform: device.platform,
                pairedAt: device.pairedAt.timeIntervalSince1970, lastSeenAt: device.lastSeenAt?.timeIntervalSince1970,
                connected: connected.contains(device.id)
            )
        }
    }

    /// Revokes the one device whose ID starts with `prefix`.
    func revoke(prefix: String) async throws -> ControlDevice {
        let matches = await controlDevices().filter { $0.id.hasPrefix(prefix) }
        guard matches.count == 1, let device = matches.first else {
            throw OptionError(matches.isEmpty ? "No paired device has the ID \(prefix)." : "\(prefix) matches several devices; give more characters.")
        }
        await runtime?.devices.revoke(device.id)
        Console.log("Removed \(device.name).")
        return device
    }
}

/// Weekly summaries are written by Apple Intelligence on the Mac (D-096);
/// the Linux host shows the numbers without the written part.
private struct UnavailableNarrator: WeeklyNarrator {
    func unavailableReason(language: String?) async -> String? {
        "Written summaries need Apple Intelligence on a Mac. The numbers are still here."
    }

    func narrate(_ summary: WeeklySummary, digests: [ProjectDigest], language: String?) async throws -> (WeeklyNarrative, [String: [String]]) {
        throw OptionError("Written summaries are not available on Linux.")
    }
}

extension String {
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}

/// Lines for `docker logs`, written at once (stdout is not a terminal there).
enum Console {
    static func log(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
