import RemoteCodeKit
import SwiftUI

/// One tool call (prompt §6.2.4): Read, Edit/Write (diff), Bash (command +
/// output), Grep/Glob, Web, TodoWrite (task list), others. In the transcript it
/// is a compact row; tapping it opens the details in a sheet, like the Claude
/// and Codex apps (D-104). The task list stays inline.
struct ToolCardView: View {
    let call: ToolCall
    let workingDirectory: String?
    /// Shown inside the detail sheet: always expanded, not tappable.
    var isDetail = false
    @State private var isExpanded: Bool
    @State private var showsDetail = false
    @Environment(\.openSubAgent) private var openSubAgent

    init(call: ToolCall, workingDirectory: String?, isDetail: Bool = false) {
        self.call = call
        self.workingDirectory = workingDirectory
        self.isDetail = isDetail
        _isExpanded = State(initialValue: isDetail || call.name == "TodoWrite")
    }

    private var summary: ToolSummary {
        ToolSummary(name: call.name, input: call.input, workingDirectory: workingDirectory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isDetail {
                header
            } else {
                Button {
                    if call.name == "TodoWrite" {
                        withAnimation(.snappy) { isExpanded.toggle() }
                    } else if summary.category == .agent, let openSubAgent {
                        // A sub-agent opens its own transcript rather than a detail sheet.
                        openSubAgent(call)
                    } else {
                        showsDetail = true
                    }
                } label: {
                    header
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shows the details"))
            }

            if isExpanded {
                Divider()
                details
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(borderColor, lineWidth: 0.75))
        .sheet(isPresented: $showsDetail) {
            ToolDetailSheet(call: call, workingDirectory: workingDirectory)
        }
        .overlay(alignment: .leading) {
            if summary.category == .agent {
                // Sub-agents get a rail in the agent's colour, so they read as their own lane.
                UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14)
                    .fill(agentTint)
                    .frame(width: 3)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tool-\(call.name)")
    }

    private var agentTint: Color {
        call.name == ToolSummary.delegationToolName ? AgentKind(call.input["agent"]?.stringValue ?? "").tint : .accentColor
    }

    private var borderColor: Color {
        if call.isError || call.decision == .denied || call.decision == .timedOut { return .red.opacity(0.4) }
        return Color(.separator).opacity(0.5)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: summary.category == .agent && call.name == ToolSummary.delegationToolName
                ? AgentKind(call.input["agent"]?.stringValue ?? "").symbol : summary.symbol)
                .font(.callout)
                .foregroundStyle(summary.category == .agent ? agentTint : Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(summary.title))
                        .font(.subheadline.weight(.semibold))
                    if let edit = diffText {
                        let stats = DiffBuilder.stats(of: edit)
                        Text(verbatim: "+\(stats.added) −\(stats.removed)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = summary.detail {
                    Text(verbatim: detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            statusView
            if !isDetail {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded && call.name == "TodoWrite" ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var statusView: some View {
        switch call.decision {
        case .denied?:
            StatusTag(text: "Denied", color: .red)
        case .timedOut?:
            StatusTag(text: "No answer", color: .red)
        case .cancelled?:
            StatusTag(text: "Cancelled", color: .secondary)
        default:
            if let result = call.result {
                Image(systemName: result.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(result.isError ? Color.red : Color.green)
                    .accessibilityLabel(result.isError ? Text("Failed") : Text("Done"))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Running"))
            }
        }
    }

    private var diffText: String? {
        call.edit?.diff ?? DiffBuilder.preview(tool: call.name, input: call.input)
    }

    @ViewBuilder private var details: some View {
        switch summary.category {
        case .edit, .write:
            if let diff = diffText {
                DiffView(diff: diff)
            }
            if let result = call.result, result.isError {
                OutputBlock(text: result.output, isError: true)
            }
        case .shell:
            VStack(alignment: .leading, spacing: 8) {
                if let command = call.input["command"]?.stringValue {
                    ShellCommandView(command: command)
                }
                if let description = call.input["description"]?.stringValue {
                    Text(verbatim: description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let result = call.result {
                    OutputBlock(text: result.output.isEmpty ? String(localized: "(no output)") : result.output, isError: result.isError)
                }
            }
        case .todo:
            TodoListView(items: TodoItem.items(from: call.input["todos"]))
        case .agent:
            VStack(alignment: .leading, spacing: 8) {
                if let prompt = call.input["prompt"]?.stringValue {
                    Text(verbatim: prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                SubAgentOpenButton(call: call)
                if let result = call.result {
                    OutputBlock(text: result.output, isError: result.isError)
                }
            }
        case .read, .search, .web:
            if let result = call.result {
                OutputBlock(text: result.output, isError: result.isError)
            }
        case .other:
            VStack(alignment: .leading, spacing: 8) {
                OutputBlock(text: call.input.jsonString(pretty: true), isError: false)
                if let result = call.result {
                    OutputBlock(text: result.output, isError: result.isError)
                }
            }
        }
    }
}

struct StatusTag: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// Coloured unified diff.
struct DiffView: View {
    let diff: String
    @State private var showAll = false
    private let limit = 300

    var body: some View {
        let lines = DiffBuilder.lines(of: diff)
        let visible = showAll ? lines : Array(lines.prefix(limit))
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { line in
                        Text(verbatim: line.text.isEmpty ? " " : line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(foreground(line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .background(background(line.kind))
                    }
                }
            }
            .background(Color(.systemBackground).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if lines.count > limit && !showAll {
                Button("Show all \(lines.count) lines") { showAll = true }
                    .font(.caption)
            }
        }
        .accessibilityLabel(Text("File changes: \(DiffBuilder.stats(of: diff).added) lines added, \(DiffBuilder.stats(of: diff).removed) lines removed"))
    }

    private func foreground(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .hunk: .secondary
        case .added: Color(.systemGreen)
        case .removed: Color(.systemRed)
        case .context: .primary
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: Color.green.opacity(0.12)
        case .removed: Color.red.opacity(0.12)
        case .hunk: Color.secondary.opacity(0.08)
        case .context: .clear
        }
    }
}

struct ShellCommandView: View {
    let command: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: "$").foregroundStyle(.secondary)
            Text(verbatim: command).textSelection(.enabled)
        }
        .font(.callout.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }
}

/// Monospaced, scrollable tool output (first 200 lines unless expanded).
struct OutputBlock: View {
    let text: String
    let isError: Bool
    @State private var showAll = false
    private let limit = 200

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = showAll || lines.count <= limit ? text : lines.prefix(limit).joined(separator: "\n")
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: shown)
                    .font(.caption.monospaced())
                    .foregroundStyle(isError ? Color.red : .primary)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            if lines.count > limit && !showAll {
                Button("Show all \(lines.count) lines") { showAll = true }
                    .font(.caption)
            }
        }
    }
}

struct TodoListView: View {
    let items: [TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(item.status))
                        .foregroundStyle(item.status == .completed ? Color.green : item.status == .inProgress ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)
                    Text(verbatim: item.content)
                        .strikethrough(item.status == .completed)
                        .foregroundStyle(item.status == .completed ? .secondary : .primary)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
                .accessibilityValue(statusText(item.status))
            }
        }
    }

    private func symbol(_ status: TodoItem.Status) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .completed: "checkmark.circle.fill"
        }
    }

    private func statusText(_ status: TodoItem.Status) -> Text {
        switch status {
        case .pending: Text("Pending")
        case .inProgress: Text("In progress")
        case .completed: Text("Completed")
        }
    }
}

/// Full details of a tool call in a sheet: the command and its output, the
/// whole diff, the file or the search results.
struct ToolDetailSheet: View {
    let call: ToolCall
    let workingDirectory: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                ToolCardView(call: call, workingDirectory: workingDirectory, isDetail: true)
                    .padding()
            }
            .gradientBackground(intensity: 0.5)
            .navigationTitle(Text(LocalizedStringKey(ToolSummary(name: call.name, input: call.input, workingDirectory: workingDirectory).title)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
