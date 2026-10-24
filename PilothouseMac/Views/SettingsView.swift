import PilothouseKit
import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ClaudeSettings()
                .tabItem { Label("Claude Code", systemImage: "terminal") }
            AgentSettings()
                .tabItem { Label("Agents", systemImage: "person.2") }
            PrivacySettings()
                .tabItem { Label("Security", systemImage: "lock.shield") }
        }
        .frame(width: 520)
        .padding(.vertical, 8)
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

private struct ClaudeSettings: View {
    @Environment(AppController.self) private var controller
    @State private var apiKey = ""

    var body: some View {
        @Bindable var settings = controller.settings
        Form {
            Section {
                LabeledContent("Version", value: controller.claude.version ?? String(localized: "Not found"))
                LabeledContent("Location", value: controller.claude.path?.abbreviatingHome ?? "—")
                Button("Check Again") { Task { await controller.refreshClaude() } }
            } header: {
                Text("Claude Code CLI")
            }
            Section {
                Picker("Default model", selection: $settings.defaultModel) {
                    ForEach(AppSettings.modelSuggestions, id: \.self) { model in
                        if model.isEmpty {
                            Text("Claude Code default").tag(model)
                        } else {
                            Text(model.capitalized).tag(model)
                        }
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
                Text("New sessions")
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
        .formStyle(.grouped)
        .onChange(of: settings.defaultModel) { _, _ in Task { await controller.applySettings() } }
        .onChange(of: settings.defaultPermissionMode) { _, _ in Task { await controller.applySettings() } }
    }
}

/// Other agent CLIs: what was found, and which ones Claude may delegate to.
private struct AgentSettings: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        Form {
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
