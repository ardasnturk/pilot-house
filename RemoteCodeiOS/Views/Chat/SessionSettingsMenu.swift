import RemoteCodeKit
import SwiftUI

/// Model, effort and permission pickers for one chat, shown as submenus of a
/// `Menu`. Model and effort apply from the next message (the Mac restarts the
/// agent CLI); the permission mode can change during a reply too.
struct SessionSettingsMenuContent: View {
    let connection: MacConnection
    let session: SessionSummary
    let onError: (String) -> Void

    private var agent: AgentKind { session.agentKind }

    private var isEditable: Bool {
        connection.isConnected && !session.state.isBusy && session.state != .closed
    }

    private var status: AgentStatus? {
        connection.status?.agents?.first { $0.kind == agent }
    }

    /// The agent's own model list (Mac 1.1), else the known names; the current
    /// model is always included.
    private var models: [ModelOption] {
        var options = status?.modelOptions ?? (agent == .claude
            ? UserPreferences.modelSuggestions.filter { !$0.isEmpty }.map { ModelOption(id: $0, displayName: $0.capitalized) }
            : (status?.models ?? []).map { ModelOption(id: $0, displayName: $0) })
        if let current = session.model, !current.isEmpty, status?.modelOption(for: current) == nil,
           !options.contains(where: { $0.id == current }) {
            options.insert(ModelOption(id: current, displayName: current), at: 0)
        }
        return options
    }

    /// The model as the CLI names it ("Opus 5.5"), not its ID.
    private var currentModelName: String {
        if let option = status?.modelOption(for: session.model), session.model?.isEmpty == false {
            return option.displayName
        }
        return session.model ?? String(localized: "Agent default")
    }

    private var permissionModes: [PermissionMode] {
        var modes = PermissionMode.standardModes
        if connection.status?.bypassPermissionsAllowed == true || session.permissionMode == .bypassPermissions {
            modes.append(.bypassPermissions)
        }
        return modes
    }

    private var effortLevels: [String] {
        status?.effortLevels(for: session.model) ?? agent.effortLevels
    }

    /// The picker's selection: the matching option's ID for a resolved name.
    private var selectedModelID: String {
        guard let model = session.model, !model.isEmpty else { return "" }
        return models.first { $0.id == model }?.id ?? status?.modelOption(for: model)?.id ?? model
    }

    var body: some View {
        Picker(selection: Binding {
            selectedModelID
        } set: { value in
            apply { connection in try await connection.updateSessionSettings(session.id, model: value) }
        }) {
            Text("Agent default").tag("")
            ForEach(models.filter { !$0.isOlder }, id: \.id) { option in
                Text(verbatim: option.displayName).tag(option.id)
            }
            let older = models.filter(\.isOlder)
            if !older.isEmpty {
                Section {
                    ForEach(older, id: \.id) { option in
                        Text(verbatim: option.displayName).tag(option.id)
                    }
                } header: {
                    Text("Earlier models")
                }
            }
        } label: {
            Label {
                Text("Model")
                Text(verbatim: currentModelName)
            } icon: {
                Image(systemName: "cpu")
            }
        }
        .pickerStyle(.menu)
        .disabled(!isEditable)
        .accessibilityIdentifier("modelMenu")
        if !effortLevels.isEmpty {
            Picker(selection: Binding {
                session.effort ?? ""
            } set: { value in
                apply { connection in try await connection.updateSessionSettings(session.id, effort: value) }
            }) {
                Text("Agent default").tag("")
                ForEach(effortLevels, id: \.self) { level in
                    Text(EffortLevel.localizedName(level)).tag(level)
                }
            } label: {
                Label {
                    Text("Effort")
                    if let effort = session.effort {
                        Text(EffortLevel.localizedName(effort))
                    } else {
                        Text("Agent default")
                    }
                } icon: {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                }
            }
            .pickerStyle(.menu)
            .disabled(!isEditable)
            .accessibilityIdentifier("effortMenu")
        }
        if connection.capabilities.contains(HostCapability.sessionPermissionMode) {
            Picker(selection: Binding {
                session.permissionMode
            } set: { value in
                apply { connection in try await connection.updateSessionSettings(session.id, permissionMode: value) }
            }) {
                ForEach(permissionModes, id: \.self) { mode in
                    Text(mode.localizedName).tag(mode)
                }
            } label: {
                Label {
                    Text("Permissions")
                    Text(session.permissionMode.localizedName)
                } icon: {
                    Image(systemName: "checkmark.shield")
                }
            }
            .pickerStyle(.menu)
            .disabled(!connection.isConnected || session.state == .closed)
            .accessibilityIdentifier("permissionModeMenu")
        }
        if session.state.isBusy {
            Text("You can change the model and effort when the reply has finished.")
        }
    }

    private func apply(_ change: @escaping @MainActor (MacConnection) async throws -> Void) {
        let connection = connection
        Task {
            do {
                try await change(connection)
                Haptics.success()
            } catch {
                onError((error as? ErrorPayload)?.message ?? error.localizedDescription)
            }
        }
    }
}
