import Observation
import PilothouseKit
import SwiftUI

/// A compact, read-mostly transcript for sessions started on the Mac itself
/// (the Tailscale assistant). The same session is visible on paired phones.
@MainActor
@Observable
final class SessionMonitor {
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable {
            case user
            case assistant
            case tool
            case output
            case notice
        }

        let id: String
        var kind: Kind
        var text: String
    }

    private(set) var lines: [Line] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var index: [String: Int] = [:]

    func start(_ stream: AsyncStream<SequencedEvent>) {
        task?.cancel()
        lines = []
        index = [:]
        task = Task { [weak self] in
            for await event in stream {
                self?.apply(event)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func apply(_ event: SequencedEvent) {
        switch event.event {
        case .userMessage(let message):
            upsert(Line(id: "seq-\(event.seq)", kind: .user, text: message.text))
        case .assistantTextDelta(let delta):
            if let position = index[delta.blockId] {
                lines[position].text = delta.replace ? delta.text : lines[position].text + delta.text
            } else {
                upsert(Line(id: delta.blockId, kind: .assistant, text: delta.text))
            }
        case .assistantMessage(let message):
            upsert(Line(id: message.blockId, kind: .assistant, text: message.text))
        case .toolUse(let use):
            let summary = ToolSummary(name: use.name, input: use.input)
            upsert(Line(id: use.toolUseId, kind: .tool, text: [summary.title, summary.detail].compactMap { $0 }.joined(separator: " · ")))
        case .toolResult(let result):
            let trimmed = result.output.split(separator: "\n").prefix(12).joined(separator: "\n")
            upsert(Line(id: "result-\(result.toolUseId)", kind: .output, text: trimmed))
        case .systemNotice(let notice):
            upsert(Line(id: "seq-\(event.seq)", kind: .notice, text: notice.text))
        case .permissionDecision(let decision):
            upsert(Line(id: "seq-\(event.seq)", kind: .notice, text: decision.toolName + ": " + decision.outcome.rawValue))
        default:
            break
        }
    }

    private func upsert(_ line: Line) {
        if let position = index[line.id] {
            lines[position] = line
        } else {
            index[line.id] = lines.count
            lines.append(line)
        }
    }
}

struct SessionMonitorView: View {
    let sessionId: String
    @Environment(AppController.self) private var controller
    @State private var monitor = SessionMonitor()
    @State private var reply = ""

    private var session: SessionSummary? {
        controller.sessions.first { $0.id == sessionId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(monitor.lines) { line in
                        lineView(line)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .frame(minHeight: 220)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

            ForEach(controller.pendingRequests.filter { $0.sessionId == sessionId }) { request in
                PermissionApprovalRow(request: request)
            }

            HStack {
                if session?.state.isBusy == true {
                    ProgressView().controlSize(.small)
                    Button("Stop") { Task { await controller.interrupt(sessionId) } }
                }
                TextField("Reply to Claude (e.g. “I have signed in”)", text: $reply)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send)
                    .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task(id: sessionId) {
            if let stream = await controller.events(of: sessionId) {
                monitor.start(stream)
            }
        }
        .onDisappear { monitor.stop() }
    }

    @ViewBuilder private func lineView(_ line: SessionMonitor.Line) -> some View {
        switch line.kind {
        case .user:
            Text(verbatim: line.text)
                .font(.callout)
                .padding(8)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        case .assistant:
            Text(LocalizedStringKey(line.text))
                .font(.callout)
                .textSelection(.enabled)
        case .tool:
            Label {
                Text(verbatim: line.text).font(.callout.monospaced())
            } icon: {
                Image(systemName: "wrench.and.screwdriver")
            }
            .foregroundStyle(.secondary)
        case .output:
            Text(verbatim: line.text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 22)
        case .notice:
            Text(verbatim: line.text)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reply = ""
        Task { await controller.send(text, to: sessionId) }
    }
}

/// Allow/Deny for a permission request, answered on the Mac.
struct PermissionApprovalRow: View {
    let request: PermissionRequest
    @Environment(AppController.self) private var controller

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude wants to use \(request.tool)")
                    .font(.callout.weight(.semibold))
                Text(verbatim: request.summary)
                    .font(.caption.monospaced())
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Deny", role: .destructive) {
                Task { await controller.respond(to: request, allow: false) }
            }
            Button("Allow") {
                Task { await controller.respond(to: request, allow: true) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}
