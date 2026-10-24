import PilothouseKit
import SwiftUI

/// Model and effort pickers for one chat, shown as submenus of a `Menu`.
/// A change applies from the next message (the Mac restarts the agent CLI).
struct SessionSettingsMenuContent: View {
    let connection: MacConnection
    let session: SessionSummary
    let onError: (String) -> Void

    private var agent: AgentKind { session.agentKind }

    private var isEditable: Bool {
        connection.isConnected && !session.state.isBusy && session.state != .closed
    }

    /// Suggestions for the agent, plus the current model when it is not among them.
    private var models: [String] {
        var names = agent == .claude
            ? UserPreferences.modelSuggestions.filter { !$0.isEmpty }
            : connection.status?.availableAgents.first { $0.kind == agent }?.models ?? []
        if let current = session.model, !current.isEmpty, !names.contains(current) {
            names.insert(current, at: 0)
        }
        return names
    }

    var body: some View {
        Picker(selection: binding(\.model) { connection, value in
            try await connection.updateSessionSettings(session.id, model: value)
        }) {
            Text("Agent default").tag("")
            ForEach(models, id: \.self) { name in
                Text(verbatim: name).tag(name)
            }
        } label: {
            Label {
                Text("Model")
                Text(verbatim: session.model ?? String(localized: "Agent default"))
            } icon: {
                Image(systemName: "cpu")
            }
        }
        .pickerStyle(.menu)
        .disabled(!isEditable)
        .accessibilityIdentifier("modelMenu")
        if !agent.effortLevels.isEmpty {
            Picker(selection: binding(\.effort) { connection, value in
                try await connection.updateSessionSettings(session.id, effort: value)
            }) {
                Text("Agent default").tag("")
                ForEach(agent.effortLevels, id: \.self) { level in
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
        if session.state.isBusy {
            Text("You can change these when the reply has finished.")
        }
    }

    private func binding(
        _ keyPath: KeyPath<SessionSummary, String?>,
        apply: @escaping @MainActor (MacConnection, String) async throws -> Void
    ) -> Binding<String> {
        Binding {
            session[keyPath: keyPath] ?? ""
        } set: { value in
            let connection = connection
            Task {
                do {
                    try await apply(connection, value)
                    Haptics.success()
                } catch {
                    onError((error as? ErrorPayload)?.message ?? error.localizedDescription)
                }
            }
        }
    }
}
