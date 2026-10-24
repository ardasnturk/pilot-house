import PilothouseHost
import PilothouseKit
import SwiftUI

/// The Settings window (⌘,): a sidebar of panes like System Settings (D-104).
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, devices, agents, notifications, remoteAccess, updates, security
        var id: String { rawValue }
    }

    @State private var pane: Pane = .general

    var body: some View {
        HStack(spacing: 0) {
            List(Pane.allCases, selection: $pane) { pane in
                Label {
                    title(pane)
                } icon: {
                    IconBadge(symbol: symbol(pane), colors: colors(pane), size: 22)
                }
                .padding(.vertical, 3)
                .tag(pane)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 210)
            .background(.thinMaterial)
            Divider()
            VStack(spacing: 0) {
                PaneHeader(symbol: symbol(pane), colors: colors(pane), title: title(pane), subtitle: subtitle(pane))
                detail
                    .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandBackground(intensity: 0.45))
        }
        .frame(width: 780, height: 560)
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .general: GeneralSettings()
        case .devices: DeviceSettings()
        case .agents: AgentSettings()
        case .notifications: NotificationSettings()
        case .remoteAccess: RemoteAccessSettings()
        case .updates: UpdateSettings()
        case .security: PrivacySettings()
        }
    }

    private func title(_ pane: Pane) -> Text {
        switch pane {
        case .general: Text("General")
        case .devices: Text("iPhone & iPad")
        case .agents: Text("Agents")
        case .notifications: Text("Notifications")
        case .remoteAccess: Text("Remote Access")
        case .updates: Text("Updates")
        case .security: Text("Security")
        }
    }

    private func subtitle(_ pane: Pane) -> Text {
        switch pane {
        case .general: Text("Start at login, keep your Mac awake, session history.")
        case .devices: Text("Paired devices and how they reach this Mac.")
        case .agents: Text("Claude Code, Codex and Gemini on this Mac, defaults and sub-agents.")
        case .notifications: Text("When and where Pilothouse tells you something happened.")
        case .remoteAccess: Text("Optional: reach this Mac when you are away from its Wi-Fi.")
        case .updates: Text("Install new versions of Pilothouse from GitHub.")
        case .security: Text("Encryption, identity and risky modes.")
        }
    }

    private func symbol(_ pane: Pane) -> String {
        switch pane {
        case .general: "gearshape.fill"
        case .devices: "iphone"
        case .agents: "sparkles"
        case .notifications: "bell.badge.fill"
        case .remoteAccess: "network"
        case .updates: "arrow.down.circle.fill"
        case .security: "lock.shield.fill"
        }
    }

    private func colors(_ pane: Pane) -> [Color] {
        switch pane {
        case .general: [.gray, Color(white: 0.35)]
        case .devices: [Brand.teal, Brand.indigo]
        case .agents: [Brand.violet, Brand.pink]
        case .notifications: [.red, .orange]
        case .remoteAccess: [Brand.indigo, Brand.violet]
        case .updates: [.green, Brand.teal]
        case .security: [.blue, Brand.indigo]
        }
    }
}

/// Large icon, title and one-line explanation at the top of a pane.
private struct PaneHeader: View {
    let symbol: String
    let colors: [Color]
    let title: Text
    let subtitle: Text

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: symbol, colors: colors, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                title.font(.title2.weight(.bold))
                subtitle
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 6)
    }
}

/// Paired devices, the pairing button and the addresses phones connect to.
private struct DeviceSettings: View {
    @Environment(AppController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                if controller.devices.isEmpty {
                    Text("No devices paired yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.devices) { device in
                    DeviceRow(device: device, isConnected: controller.connectedDeviceIds.contains(device.id)) {
                        Task { await controller.revoke(device) }
                    }
                }
                HStack {
                    Button {
                        Task { await controller.createPairing() }
                        openWindow(id: WindowID.pairing)
                        NSApp.activate()
                    } label: {
                        Label("Pair iPhone or iPad…", systemImage: "qrcode")
                    }
                    .disabled(controller.phase != .running)
                    Button("Get the iPhone App…") {
                        openWindow(id: WindowID.iPhoneApp)
                        NSApp.activate()
                    }
                }
            } header: {
                Text("Paired devices")
            } footer: {
                Text("A revoked device is disconnected at once and has to pair again.")
            }
            Section {
                if controller.reachableAddresses.isEmpty {
                    Text("No network connection.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.reachableAddresses, id: \.self) { address in
                    AddressRow(address: address, port: controller.port)
                }
            } header: {
                Text("Addresses")
            } footer: {
                Text("Your iPhone finds this Mac on the same Wi-Fi by itself; you never need to type these. Tailscale addresses are only used if you turn on Tailscale in the iPhone app.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Tailscale, explained as an optional extra.
private struct RemoteAccessSettings: View {
    @Environment(AppController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("At home or in the office you need nothing else: your iPhone talks to this Mac directly over the Wi-Fi.")
                    Text("To use Pilothouse away from that Wi-Fi, install Tailscale on this Mac and on your iPhone, sign in to the same account on both, then turn on “Use Tailscale when away” in the iPhone app's settings. Pilothouse still tries the local network first.")
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("How it works")
            }
            Section {
                LabeledContent {
                    Text(tailscaleSummary)
                        .foregroundStyle(controller.tailscale.running ? .green : .secondary)
                } label: {
                    Label("Tailscale", systemImage: "network")
                }
                if let name = controller.tailscale.magicDNSName {
                    LabeledContent("MagicDNS name", value: name)
                }
                Button("Set Up Tailscale…") {
                    openWindow(id: WindowID.tailscale)
                    NSApp.activate()
                }
            } header: {
                Text("On this Mac")
            }
        }
        .formStyle(.grouped)
    }

    private var tailscaleSummary: String {
        if controller.tailscale.running {
            return controller.tailscale.ipv4 ?? String(localized: "Connected")
        }
        return controller.tailscale.installed ? String(localized: "Not connected") : String(localized: "Not installed")
    }
}

private struct GeneralSettings: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        @Bindable var settings = controller.settings
        Form {
            Section {
                Toggle("Open Pilothouse at login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                ))
            }
            Section {
                Toggle("Stay awake with the lid closed", isOn: $settings.keepAwakeWithLidClosed)
                Toggle("Pause while on battery", isOn: $settings.pauseLidModeOnBattery)
                    .disabled(!settings.keepAwakeWithLidClosed)
            } header: {
                Text("Lid-closed mode")
            } footer: {
                Text("Uses a small privileged helper that only runs `pmset -a disablesleep`. A closed MacBook that stays awake can get warm and drain its battery; the setting is reverted when Pilothouse quits.")
            }
            Section {
                Stepper(value: $settings.retentionDays, in: 1...365) {
                    Text("Keep session logs for \(settings.retentionDays) days")
                }
                LabeledContent {
                    TextField(value: $settings.preferredPort, format: .number.grouping(.never)) {
                        Text("Port")
                    }
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                } label: {
                    Text("Preferred port")
                    Text("Takes effect after restarting Pilothouse. The next free port is used if it is taken.")
                }
            } header: {
                Text("Sessions")
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.keepAwakeWithLidClosed) { _, _ in Task { await controller.applySettings() } }
        .onChange(of: settings.pauseLidModeOnBattery) { _, _ in Task { await controller.applySettings() } }
        .onChange(of: settings.retentionDays) { _, _ in Task { await controller.applySettings() } }
    }
}

/// Claude Code's defaults and sign-in, at the top of the Agents pane.
private struct ClaudeSections: View {
    @Environment(AppController.self) private var controller
    @State private var apiKey = ""

    /// Models reported by Claude Code itself, or the aliases when it could not be asked.
    private var models: [(id: String, name: String)] {
        if let options = controller.agents.first(where: { $0.kind == .claude })?.modelOptions, !options.isEmpty {
            var list = options.map { (id: $0.id, name: $0.displayName) }
            let current = controller.settings.defaultModel
            if !current.isEmpty, !list.contains(where: { $0.id == current }) { list.insert((current, current), at: 0) }
            return list
        }
        return AppSettings.modelSuggestions.filter { !$0.isEmpty }.map { (id: $0, name: $0.capitalized) }
    }

    var body: some View {
        @Bindable var settings = controller.settings
        Group {
            Section {
                Picker("Default model", selection: $settings.defaultModel) {
                    Text("Claude Code default").tag("")
                    ForEach(models, id: \.id) { model in
                        Text(verbatim: model.name).tag(model.id)
                    }
                }
                Picker("Default permission mode", selection: $settings.defaultPermissionMode) {
                    ForEach(PermissionMode.standardModes, id: \.self) { mode in
                        Text(mode.localizedName).tag(mode)
                    }
                    if settings.allowBypassPermissions {
                        Text(PermissionMode.bypassPermissions.localizedName).tag(PermissionMode.bypassPermissions)
                    }
                }
            } header: {
                Text("Claude Code · new chats")
            } footer: {
                Text("Your iPhone can choose another model and effort for each chat.")
            }
            Section {
                Toggle("Use an Anthropic API key instead of the CLI login", isOn: $settings.useAPIKey)
                if settings.useAPIKey {
                    SecureField("API key", text: $apiKey, prompt: controller.hasAPIKey ? Text("Stored in Keychain") : Text(verbatim: "sk-ant-…"))
                    Button("Save to Keychain") {
                        controller.saveAPIKey(apiKey)
                        apiKey = ""
                    }
                    .disabled(apiKey.isEmpty)
                }
            } header: {
                Text("Authentication")
            } footer: {
                Text("By default Claude Code uses the account you signed in with in Terminal. The API key is only passed to Claude Code as ANTHROPIC_API_KEY and never leaves this Mac.")
            }
        }
        .onChange(of: settings.defaultModel) { _, _ in Task { await controller.applySettings() } }
        .onChange(of: settings.defaultPermissionMode) { _, _ in Task { await controller.applySettings() } }
    }
}

/// Other agent CLIs: what was found, and which ones Claude may delegate to.
private struct AgentSettings: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        Form {
            ClaudeSections()
            Section {
                ForEach(controller.agents) { agent in
                    AgentRow(agent: agent)
                }
                Button("Check Again") { Task { await controller.refreshClaude() } }
                    .disabled(controller.isCheckingClaude)
            } header: {
                Text("Agent CLIs on this Mac")
            } footer: {
                Text("New chats on your iPhone or iPad can use any installed agent. Each one uses its own sign-in from Terminal; Pilothouse never sees it.")
            }
            Section {
                ForEach(controller.agents.filter { $0.kind != .claude && $0.installed }) { agent in
                    Toggle(isOn: delegationBinding(agent.kind)) {
                        Text("Claude may hand tasks to \(agent.kind.displayName)")
                    }
                    .disabled(agent.loggedIn == false)
                }
            } header: {
                Text("Sub-agents")
            } footer: {
                Text("Claude Code gets a delegate_to_agent tool for these agents. Every delegation and every action of the sub-agent still needs your approval, and you can follow it live on your phone.")
            }
            Section {
                Toggle("Write weekly summaries on this Mac", isOn: Binding(
                    get: { controller.settings.weeklySummaryEnabled },
                    set: { value in
                        controller.settings.weeklySummaryEnabled = value
                        Task { await controller.applySettings() }
                    }
                ))
                if let reason = controller.summaryUnavailableReason {
                    Label(reason, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Apple Intelligence is ready.", systemImage: "apple.intelligence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Weekly summary")
            } footer: {
                Text("Your phone shows what you worked on each week. The numbers come from the session logs on this Mac; the written part is generated on this Mac by Apple Intelligence and never leaves it.")
            }
        }
        .formStyle(.grouped)
    }

    private func delegationBinding(_ kind: AgentKind) -> Binding<Bool> {
        Binding {
            controller.settings.delegationAgents.contains(kind)
        } set: { enabled in
            if enabled {
                controller.settings.delegationAgents.insert(kind)
            } else {
                controller.settings.delegationAgents.remove(kind)
            }
            Task { await controller.applyDelegationSettings() }
        }
    }
}

private struct AgentRow: View {
    let agent: AgentStatus

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if agent.installed {
                    Text(verbatim: agent.version ?? "")
                        .foregroundStyle(.secondary)
                    if agent.loggedIn == false {
                        Text("Not signed in").foregroundStyle(.orange)
                    }
                } else {
                    Text("Not found").foregroundStyle(.secondary)
                }
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: agent.kind.displayName)
                    if let path = agent.path {
                        Text(verbatim: path.abbreviatingHome)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: agent.installed ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(agent.installed ? (agent.loggedIn == false ? Color.orange : Color.green) : Color.secondary)
            }
        }
    }
}

private struct PrivacySettings: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        @Bindable var settings = controller.settings
        Form {
            Section {
                Toggle(isOn: $settings.allowBypassPermissions) {
                    Text("Allow “Bypass permissions” mode")
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("When allowed, a paired device can start sessions in which Claude edits files and runs commands without asking. Only enable this if you understand the risk.")
                    .foregroundStyle(.red)
            }
            Section {
                LabeledContent("Mac ID", value: controller.macFingerprint)
                if let url = AppInfo.repositoryURL {
                    Link("Read the security model", destination: url.appendingPathComponent("blob/main/docs/SECURITY.md"))
                }
            } header: {
                Text("Identity")
            } footer: {
                Text("Traffic between your devices is end-to-end encrypted. Pilothouse never connects to Anthropic and collects no telemetry.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.allowBypassPermissions) { _, _ in Task { await controller.applySettings() } }
    }
}

/// Native and ntfy notifications (docs/DECISIONS.md D-095).
private struct NotificationSettings: View {
    @Environment(AppController.self) private var controller
    @State private var token = ""

    var body: some View {
        @Bindable var settings = controller.settings
        Form {
            Section {
                Toggle("Send notifications", isOn: $settings.notificationsEnabled)
            } footer: {
                Text("Get notified when a task you started from your phone finishes, when Claude waits for your approval, or when a session fails.")
            }
            Section {
                Toggle("Task finished", isOn: kind(.turnFinished))
                Toggle("Approval needed", isOn: kind(.permissionRequested))
                Toggle("Session failed", isOn: kind(.sessionFailed))
                Toggle("Include a short summary", isOn: $settings.notificationIncludesSummary)
            } header: {
                Text("Events")
            } footer: {
                Text("Without a summary, a notification only says what happened and in which folder, e.g. “Task finished · my-app”. With it, the last message, the tool or the error is added.")
            }
            .disabled(!settings.notificationsEnabled)
            Section {
                Toggle("Show on this Mac", isOn: $settings.notifyOnMac)
                Toggle("Send to your iPhone with ntfy", isOn: $settings.notifyViaNtfy)
            } header: {
                Text("Destinations")
            } footer: {
                Text("iPhone notifications go through an ntfy server, because iOS only wakes apps through Apple's push service, which would need a Pilothouse server. Tapping one opens the session in Pilothouse.")
            }
            .disabled(!settings.notificationsEnabled)
            if settings.notifyViaNtfy {
                ntfySection(settings)
                subscribeSection(settings)
            }
            Section {
                HStack {
                    Button("Send Test Notification") {
                        Task { await controller.sendTestNotification() }
                    }
                    .disabled(controller.notificationTest == .sending || (!settings.notifyOnMac && !settings.notifyViaNtfy))
                    Spacer()
                    testStatus
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.notificationsEnabled) { _, _ in Task { await controller.applyNotificationSettings() } }
        .onChange(of: settings.notifyOnMac) { _, _ in Task { await controller.applyNotificationSettings() } }
        .onChange(of: settings.notifyViaNtfy) { _, _ in Task { await controller.applyNotificationSettings() } }
        .onChange(of: settings.notificationKinds) { _, _ in Task { await controller.applyNotificationSettings() } }
        .onChange(of: settings.notificationIncludesSummary) { _, _ in Task { await controller.applyNotificationSettings() } }
        .onChange(of: settings.ntfyServer) { _, _ in Task { await controller.applyNotificationSettings() } }
    }

    private func ntfySection(_ settings: AppSettings) -> some View {
        @Bindable var settings = settings
        return Section {
            TextField("Server", text: $settings.ntfyServer, prompt: Text(verbatim: NtfyConfiguration.defaultServer))
            LabeledContent("Topic") {
                HStack {
                    Text(verbatim: settings.ntfyTopic)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Button {
                        controller.regenerateNtfyTopic()
                    } label: {
                        Label("New Topic", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .help(Text("Create a new random topic. Phones subscribed to the old one stop receiving notifications."))
                }
            }
            SecureField("Access token", text: $token, prompt: controller.hasNtfyToken ? Text("Stored in Keychain") : Text("Optional"))
            HStack {
                Button("Save to Keychain") {
                    controller.saveNtfyToken(token)
                    token = ""
                }
                .disabled(token.isEmpty)
                if controller.hasNtfyToken {
                    Button("Remove Token") { controller.saveNtfyToken("") }
                }
            }
        } header: {
            Text("ntfy")
        } footer: {
            if controller.ntfyConfiguration == nil {
                Text("Enter a valid server address (https://…).")
                    .foregroundStyle(.red)
            } else {
                Text("On a public server anyone who knows the topic can read its notifications, so treat it like a password. Self-hosted servers need HTTPS; an access token is only needed if your server requires one.")
            }
        }
    }

    private func subscribeSection(_ settings: AppSettings) -> some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let url = controller.ntfyConfiguration?.topicURL, let image = QRCode.image(for: url.absoluteString, scale: 6) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "qrcode").font(.system(size: 80))
                    }
                }
                .frame(width: 120, height: 120)
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(Text("ntfy topic QR code"))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install the free ntfy app, tap +, and enter the topic. For a self-hosted server, also turn on “Use another server” and enter its address.")
                    Text("Or scan the code with the Camera to open the topic in Safari.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Link("ntfy on the App Store", destination: NtfyConfiguration.iOSAppURL)
                        Button("Copy Topic") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(settings.ntfyTopic, forType: .string)
                        }
                    }
                }
                .font(.callout)
            }
        } header: {
            Text("Subscribe on your iPhone")
        }
    }

    @ViewBuilder private var testStatus: some View {
        switch controller.notificationTest {
        case .sending:
            ProgressView().controlSize(.small)
        case .sent(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }

    private func kind(_ kind: HostAlert.Kind) -> Binding<Bool> {
        Binding(
            get: { controller.settings.notificationKinds.contains(kind) },
            set: { isOn in
                if isOn {
                    controller.settings.notificationKinds.insert(kind)
                } else {
                    controller.settings.notificationKinds.remove(kind)
                }
            }
        )
    }
}

/// Version, update checks and installing (AppUpdater, D-105).
private struct UpdateSettings: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        @Bindable var settings = controller.settings
        let updater = controller.updater
        Form {
            Section {
                LabeledContent("Installed version", value: updater.currentVersion)
                UpdateStatusView(updater: updater)
                Toggle("Check for updates automatically", isOn: $settings.automaticallyChecksForUpdates)
            } footer: {
                Text("Pilothouse looks for a new release on GitHub once a day. Updates are only installed when you click Install; they are checked for Apple's notarization and the same developer signature first.")
            }
            if case .available = updater.state, !updater.releaseNotes.isEmpty {
                Section {
                    ScrollView {
                        Text(LocalizedStringKey(updater.releaseNotes))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                } header: {
                    Text("What's new")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The update state with its action: check, install, progress or error.
struct UpdateStatusView: View {
    let updater: AppUpdater

    var body: some View {
        HStack(spacing: 10) {
            switch updater.state {
            case .idle:
                Text("Not checked yet").foregroundStyle(.secondary)
                Spacer()
                checkButton
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
                Spacer()
            case .upToDate:
                Label("Pilothouse is up to date", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                checkButton
            case .available(let release):
                Label {
                    Text("Version \(release.version.description) is available")
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(Brand.violet)
                }
                Spacer()
                Button("Install and Relaunch") { Task { await updater.installUpdate() } }
                    .buttonStyle(.borderedProminent)
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text("Downloading…")
                }
            case .installing:
                ProgressView().controlSize(.small)
                Text("Installing…").foregroundStyle(.secondary)
                Spacer()
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                checkButton
            }
        }
    }

    private var checkButton: some View {
        Button("Check Now") { Task { await updater.checkForUpdates(userInitiated: true) } }
    }
}
