import RemoteCodeKit
import SwiftUI

/// Opens the live transcript of a sub-agent tool call (`Task`, `delegate_to_agent`).
struct OpenSubAgentAction {
    let open: (ToolCall) -> Void
    func callAsFunction(_ call: ToolCall) { open(call) }
}

extension EnvironmentValues {
    @Entry var openSubAgent: OpenSubAgentAction?
}

/// The sub-agent a sheet shows.
struct SubAgentSelection: Identifiable, Equatable {
    var call: ToolCall
    var id: String { call.id }
}

/// Chips for the sub-agents that are running now, above the composer.
struct RunningSubAgentsBar: View {
    let calls: [ToolCall]
    let workingDirectory: String?
    @Environment(\.openSubAgent) private var openSubAgent

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(calls, id: \.id) { call in
                    let summary = ToolSummary(name: call.name, input: call.input, workingDirectory: workingDirectory)
                    Button {
                        openSubAgent?(call)
                    } label: {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(LocalizedStringKey(summary.title))
                                .font(.caption.weight(.semibold))
                            if let detail = summary.detail {
                                Text(verbatim: detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: 160, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("runningSubAgent")
                    .accessibilityHint(Text("Shows what the sub-agent is doing"))
                }
            }
        }
    }
}

/// "Follow live" row inside a sub-agent tool card.
struct SubAgentOpenButton: View {
    let call: ToolCall
    @Environment(\.openSubAgent) private var openSubAgent

    var body: some View {
        if let openSubAgent {
            Button {
                openSubAgent(call)
            } label: {
                Group {
                    if call.isFinished {
                        Label("Show Transcript", systemImage: "rectangle.stack")
                    } else {
                        Label("Follow Live", systemImage: "rectangle.stack")
                    }
                }
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("openSubAgent")
        }
    }
}

/// The transcript of one sub-agent, in its own window (sheet).
struct SubAgentTranscriptView: View {
    let connection: MacConnection
    let sessionId: String
    let call: ToolCall
    let workingDirectory: String?
    @Environment(\.dismiss) private var dismiss

    private var parent: ChatState { connection.chat(for: sessionId) }
    private var thread: ChatState? { parent.thread(call.id) }
    /// The parent's latest view of the call (its result arrives there).
    private var current: ToolCall {
        for item in parent.items {
            if case .tool(let latest) = item.kind, latest.id == call.id { return latest }
        }
        return call
    }

    private var summary: ToolSummary {
        ToolSummary(name: call.name, input: call.input, workingDirectory: workingDirectory)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header
                    if let thread, !thread.items.isEmpty {
                        ForEach(thread.items) { item in
                            TranscriptItemView(item: item, workingDirectory: workingDirectory)
                        }
                    } else if current.isFinished {
                        Label("This sub-agent left no transcript.", systemImage: "tray")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Waiting for the sub-agent…", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                    }
                    if let result = current.result {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Answer to Claude")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            OutputBlock(text: result.output, isError: result.isError)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .navigationTitle(Text(LocalizedStringKey(summary.title)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text(LocalizedStringKey(summary.title)).font(.headline)
                        if !current.isFinished {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private var header: some View {
        let prompt = call.input["prompt"]?.stringValue ?? call.input["description"]?.stringValue
        if let prompt {
            VStack(alignment: .leading, spacing: 4) {
                Text("Task")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: prompt)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Small capsule naming the agent of a session (shown for agents other than Claude).
struct AgentBadge: View {
    let agent: AgentKind

    var body: some View {
        Text(verbatim: agent.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .accessibilityLabel(Text("Agent: \(agent.displayName)"))
    }
}
