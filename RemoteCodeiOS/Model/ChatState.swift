import Foundation
import Observation
import RemoteCodeKit

/// A tool call as shown in the transcript, with its result attached later.
struct ToolCall: Equatable {
    var id: String
    var name: String
    var input: JSONValue
    var result: SessionEvent.ToolResult?
    var edit: SessionEvent.FileEdit?
    var decision: SessionEvent.PermissionDecision.Outcome?

    var isFinished: Bool { result != nil }
    var isError: Bool { result?.isError ?? false }
}

/// One row of the chat transcript.
struct TranscriptItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(text: String, attachments: Int)
        case assistant(text: String, isStreaming: Bool)
        case thinking(text: String, isComplete: Bool)
        case tool(ToolCall)
        case notice(SessionEvent.SystemNotice)
        case turnEnd(SessionEvent.TurnResult)
        case permission(SessionEvent.PermissionDecision)
    }

    let id: String
    var kind: Kind
    var timestamp: Date
}

/// The transcript of one session, built by folding `SequencedEvent`s.
///
/// Persisted events advance `lastSeq` and are de-duplicated by sequence
/// number (catch-up after a reconnect may overlap); ephemeral deltas only
/// update the streaming text.
@MainActor
@Observable
final class ChatState {
    let sessionId: String
    private(set) var items: [TranscriptItem] = []
    private(set) var lastSeq = 0
    private(set) var info: SessionEvent.SessionInfo?
    /// Transcripts of sub-agents (Claude `Task`, `delegate_to_agent`), by the
    /// tool-use ID that started them.
    private(set) var threads: [String: ChatState] = [:]
    @ObservationIgnored private var indexById: [String: Int] = [:]
    /// Thumbnails of photos and videos this device sent, by user-message item
    /// ID. Kept in memory only; the Mac's transcript has the count.
    private(set) var thumbnails: [String: [Data]] = [:]
    @ObservationIgnored private var outgoingThumbnails: [(text: String, images: [Data])] = []

    /// Remembers thumbnails until the Mac echoes the message they belong to.
    func noteOutgoing(text: String, thumbnails: [Data]) {
        guard !thumbnails.isEmpty else { return }
        outgoingThumbnails.append((text, thumbnails))
    }

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    /// Folds many events at once (cache replay).
    func replay(_ events: [SequencedEvent]) {
        for event in events { apply(event) }
    }

    func apply(_ event: SequencedEvent) {
        if !event.ephemeral {
            guard event.seq > lastSeq else { return }
            lastSeq = event.seq
        }
        if let thread = event.thread {
            let child = threads[thread] ?? ChatState(sessionId: "\(sessionId)#\(thread)")
            if threads[thread] == nil { threads[thread] = child }
            var plain = event
            plain.thread = nil
            child.apply(plain)
            return
        }
        let date = event.timestamp
        switch event.event {
        case .userMessage(let message):
            let id = "seq-\(event.seq)"
            if message.attachmentCount > 0, let index = outgoingThumbnails.firstIndex(where: { $0.text == message.text }) {
                thumbnails[id] = outgoingThumbnails.remove(at: index).images
            }
            append(TranscriptItem(id: id, kind: .user(text: message.text, attachments: message.attachmentCount), timestamp: date))

        case .assistantTextDelta(let delta):
            if let index = indexById[delta.blockId] {
                guard case .assistant(let text, true) = items[index].kind else { return }
                items[index].kind = .assistant(text: delta.replace ? delta.text : text + delta.text, isStreaming: true)
            } else {
                append(TranscriptItem(id: delta.blockId, kind: .assistant(text: delta.text, isStreaming: true), timestamp: date))
            }

        case .assistantMessage(let message):
            upsert(TranscriptItem(id: message.blockId, kind: .assistant(text: message.text, isStreaming: false), timestamp: date))

        case .thinking(let thinking):
            let id = "thinking-\(thinking.blockId)"
            if let index = indexById[id], case .thinking(let existing, true) = items[index].kind, !thinking.isComplete {
                items[index].kind = .thinking(text: existing, isComplete: true)
                return
            }
            upsert(TranscriptItem(id: id, kind: .thinking(text: thinking.text, isComplete: thinking.isComplete), timestamp: date))

        case .toolUse(let use):
            upsert(TranscriptItem(id: use.toolUseId, kind: .tool(ToolCall(id: use.toolUseId, name: use.name, input: use.input)), timestamp: date))

        case .toolResult(let result):
            updateTool(result.toolUseId, date: date) { $0.result = result }

        case .fileEdit(let edit):
            updateTool(edit.toolUseId, date: date) { $0.edit = edit }

        case .permissionDecision(let decision):
            if let index = items.lastIndex(where: { item in
                if case .tool(let call) = item.kind {
                    return call.name == decision.toolName && call.result == nil && call.decision == nil
                }
                return false
            }), case .tool(var call) = items[index].kind {
                call.decision = decision.outcome
                items[index].kind = .tool(call)
            } else {
                append(TranscriptItem(id: "seq-\(event.seq)", kind: .permission(decision), timestamp: date))
            }

        case .result(let result):
            finishStreaming()
            append(TranscriptItem(id: "seq-\(event.seq)", kind: .turnEnd(result), timestamp: date))

        case .systemNotice(let notice):
            append(TranscriptItem(id: "seq-\(event.seq)", kind: .notice(notice), timestamp: date))

        case .sessionInfo(let sessionInfo):
            info = sessionInfo
        }
    }

    /// The sub-agent transcript started by `toolUseId`, if it produced anything.
    func thread(_ toolUseId: String) -> ChatState? {
        threads[toolUseId]
    }

    /// Sub-agent tool calls of this transcript that are still running.
    var runningSubAgents: [ToolCall] {
        items.compactMap { item in
            guard case .tool(let call) = item.kind, ToolSummary.startsThread(call.name), !call.isFinished else { return nil }
            return call
        }
    }

    /// The thread finished its own turn (delegated agents report a result).
    var hasFinishedTurn: Bool {
        items.contains { if case .turnEnd = $0.kind { true } else { false } }
    }

    /// Marks streaming blocks as finished (e.g. after an interrupt).
    func finishStreaming() {
        for index in items.indices {
            switch items[index].kind {
            case .assistant(let text, true): items[index].kind = .assistant(text: text, isStreaming: false)
            case .thinking(let text, false): items[index].kind = .thinking(text: text, isComplete: true)
            default: break
            }
        }
    }

    /// Text of the last assistant message (for copying).
    var lastAssistantText: String? {
        for item in items.reversed() {
            if case .assistant(let text, _) = item.kind { return text }
        }
        return nil
    }

    /// The newest unfinished tool call, shown in the "working" indicator.
    var runningTool: ToolCall? {
        for item in items.reversed() {
            if case .tool(let call) = item.kind { return call.isFinished ? nil : call }
            if case .turnEnd = item.kind { return nil }
        }
        return nil
    }

    var todos: JSONValue? {
        for item in items.reversed() {
            if case .tool(let call) = item.kind, call.name == "TodoWrite" { return call.input["todos"] }
        }
        return nil
    }

    // MARK: Helpers

    private func append(_ item: TranscriptItem) {
        if let index = indexById[item.id] {
            items[index] = item
            return
        }
        indexById[item.id] = items.count
        items.append(item)
    }

    private func upsert(_ item: TranscriptItem) {
        if let index = indexById[item.id] {
            if case .tool(let existing) = items[index].kind, case .tool(var updated) = item.kind {
                updated.result = existing.result
                updated.edit = existing.edit
                updated.decision = existing.decision
                items[index].kind = .tool(updated)
            } else {
                items[index].kind = item.kind
            }
        } else {
            append(item)
        }
    }

    private func updateTool(_ id: String, date: Date, change: (inout ToolCall) -> Void) {
        if let index = indexById[id], case .tool(var call) = items[index].kind {
            change(&call)
            items[index].kind = .tool(call)
        } else {
            var call = ToolCall(id: id, name: "Tool", input: [:])
            change(&call)
            append(TranscriptItem(id: id, kind: .tool(call), timestamp: date))
        }
    }
}
