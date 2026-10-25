import Foundation
import RemoteCodeKit

/// Turns Claude Code `stream-json` output lines into `SessionEvent`s.
///
/// Based on the format emitted by Claude Code 2.1.x with `--verbose
/// --include-partial-messages` (fixtures in `Tests/RemoteCodeHostTests/Fixtures`):
///
/// * `system/init` → `sessionInfo`; `system/api_retry`, `compact_boundary` → notices
/// * `stream_event` `text_delta` → ephemeral `assistantTextDelta`;
///   `content_block_start` of a thinking block → ephemeral `thinking`
/// * `assistant` → `assistantMessage`, complete `thinking`, `toolUse`
/// * `user` → `toolResult` (+ `fileEdit` from `tool_use_result.structuredPatch`)
/// * `result` → `result`
///
/// Messages of sub-agents (`parent_tool_use_id != null`) are skipped by
/// `consume`; `consumeThreaded` returns them tagged with that tool-use ID.
/// Unknown line types are ignored, so newer CLI versions degrade gracefully.
public struct StreamJSONNormalizer: Sendable {
    /// Strings above this length (tool inputs/outputs, diffs) are truncated.
    public static let maximumTextLength = 64 * 1024

    public private(set) var claudeSessionId: String?
    public private(set) var model: String?
    public private(set) var slashCommands: [String] = []
    /// Text of blocks that are still streaming, by block ID.
    public private(set) var streamingText: [String: String] = [:]

    private var currentMessageId: String?
    private var lastBlockIndex: [String: Int] = [:]

    public init() {}

    /// Parses one stdout line. Non-JSON lines are ignored.
    public mutating func consume(line: String) -> [SessionEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let value = try? JSONValue.parse(trimmed) else { return [] }
        return consume(value)
    }

    /// Like `consume(line:)`, but also returns the messages of `Task`
    /// sub-agents together with the tool-use ID that started them.
    public mutating func consumeThreaded(line: String) -> (thread: String?, events: [SessionEvent]) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let value = try? JSONValue.parse(trimmed) else { return (nil, []) }
        guard let parent = value["parent_tool_use_id"]?.stringValue else { return (nil, consume(value)) }
        switch value["type"]?.stringValue {
        case "assistant": return (parent, assistant(value))
        case "user": return (parent, user(value))
        default: return (parent, [])
        }
    }

    public mutating func consume(_ value: JSONValue) -> [SessionEvent] {
        if let parent = value["parent_tool_use_id"], !parent.isNull { return [] }
        switch value["type"]?.stringValue {
        case "system": return system(value)
        case "stream_event": return streamEvent(value)
        case "assistant": return assistant(value)
        case "user": return user(value)
        case "result": return result(value)
        case "rate_limit_event": return rateLimit(value)
        default: return []
        }
    }

    // MARK: system

    private mutating func system(_ value: JSONValue) -> [SessionEvent] {
        switch value["subtype"]?.stringValue {
        case "init":
            let sessionId = value["session_id"]?.stringValue ?? claudeSessionId ?? ""
            claudeSessionId = sessionId
            model = value["model"]?.stringValue
            slashCommands = (value["slash_commands"]?.arrayValue ?? []).compactMap { entry in
                entry.stringValue ?? entry["name"]?.stringValue
            }
            let skills = value["skills"]?.arrayValue.map { $0.compactMap { $0.stringValue ?? $0["name"]?.stringValue } }
            var plugins: [String: String] = [:]
            for plugin in value["plugins"]?.arrayValue ?? [] {
                if let name = plugin["name"]?.stringValue, let path = plugin["path"]?.stringValue, path.hasPrefix("/") {
                    plugins[name] = path
                }
            }
            return [.sessionInfo(SessionEvent.SessionInfo(
                claudeSessionId: sessionId,
                model: model,
                permissionMode: value["permissionMode"]?.stringValue,
                cwd: value["cwd"]?.stringValue,
                claudeVersion: value["claude_code_version"]?.stringValue,
                slashCommands: slashCommands,
                skills: skills,
                plugins: plugins.isEmpty ? nil : plugins
            ))]
        case "api_retry":
            let attempt = value["attempt"]?.intValue ?? 0
            let maxRetries = value["max_retries"]?.intValue ?? 0
            let delay = Double(value["retry_delay_ms"]?.intValue ?? 0) / 1_000
            let status = value["error_status"]?.intValue.map { " \($0)" } ?? ""
            let category = value["error"]?.stringValue ?? "unknown"
            if category == "authentication_failed" {
                return [Self.loginRequiredNotice]
            }
            let text = "Claude API error\(status) (\(category)). Retrying in \(String(format: "%.0f", delay)) s (attempt \(attempt) of \(maxRetries))…"
            return [.systemNotice(.init(kind: "apiRetry", level: .warning, text: text))]
        case "compact_boundary":
            return [.systemNotice(.init(kind: "compacted", level: .info, text: "The conversation was compacted to free up context."))]
        case "permission_denied":
            let tool = value["tool_name"]?.stringValue ?? "A tool"
            return [.systemNotice(.init(kind: "permissionDenied", level: .warning, text: "\(tool) was denied by your Claude Code permission settings."))]
        default:
            return []
        }
    }

    static let loginRequiredNotice = SessionEvent.systemNotice(.init(
        kind: "loginRequired",
        level: .error,
        text: "Claude Code is not signed in on this Mac. Open Terminal, run `claude` and sign in, then try again."
    ))

    // MARK: stream_event

    private mutating func streamEvent(_ value: JSONValue) -> [SessionEvent] {
        guard let event = value["event"] else { return [] }
        let messageId = value["api_message_id"]?.stringValue ?? currentMessageId ?? "message"
        switch event["type"]?.stringValue {
        case "message_start":
            currentMessageId = event["message"]?["id"]?.stringValue ?? value["api_message_id"]?.stringValue
            return []
        case "content_block_start":
            let index = event["index"]?.intValue ?? 0
            lastBlockIndex[messageId] = index
            let blockId = "\(messageId):\(index)"
            switch event["content_block"]?["type"]?.stringValue {
            case "thinking", "redacted_thinking":
                return [.thinking(.init(blockId: blockId, text: "", isComplete: false))]
            case "text":
                streamingText[blockId] = ""
                return []
            default:
                return []
            }
        case "content_block_delta":
            let index = event["index"]?.intValue ?? 0
            let blockId = "\(messageId):\(index)"
            guard event["delta"]?["type"]?.stringValue == "text_delta", let text = event["delta"]?["text"]?.stringValue, !text.isEmpty else {
                return []
            }
            streamingText[blockId, default: ""] += text
            return [.assistantTextDelta(.init(blockId: blockId, text: text))]
        default:
            return []
        }
    }

    // MARK: assistant

    private mutating func assistant(_ value: JSONValue) -> [SessionEvent] {
        guard let message = value["message"] else { return [] }
        let messageId = message["id"]?.stringValue ?? currentMessageId ?? "message"
        let blocks = message["content"]?.arrayValue ?? []
        var events: [SessionEvent] = []
        for (position, block) in blocks.enumerated() {
            let index = blocks.count == 1 ? (lastBlockIndex[messageId] ?? 0) : position
            let blockId = "\(messageId):\(index)"
            switch block["type"]?.stringValue {
            case "text":
                streamingText.removeValue(forKey: blockId)
                let text = block["text"]?.stringValue ?? ""
                guard !text.isEmpty else { continue }
                events.append(.assistantMessage(.init(blockId: blockId, text: text)))
            case "thinking":
                events.append(.thinking(.init(blockId: blockId, text: block["thinking"]?.stringValue ?? "", isComplete: true)))
            case "redacted_thinking":
                events.append(.thinking(.init(blockId: blockId, text: "", isComplete: true)))
            case "tool_use", "server_tool_use":
                events.append(.toolUse(.init(
                    toolUseId: block["id"]?.stringValue ?? blockId,
                    name: block["name"]?.stringValue ?? "Tool",
                    input: (block["input"] ?? .object([:])).truncatingStrings(maxLength: Self.maximumTextLength)
                )))
            default:
                continue
            }
        }
        if value["error"] != nil || value["isApiErrorMessage"]?.boolValue == true {
            let text = blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            if Self.looksLikeLoginProblem(text) || value["error"]?.stringValue == "authentication_failed" {
                events.append(Self.loginRequiredNotice)
            }
        }
        return events
    }

    // MARK: user

    private mutating func user(_ value: JSONValue) -> [SessionEvent] {
        guard let blocks = value["message"]?["content"]?.arrayValue else { return [] }
        var events: [SessionEvent] = []
        var firstToolUseId: String?
        for block in blocks {
            switch block["type"]?.stringValue {
            case "tool_result":
                let toolUseId = block["tool_use_id"]?.stringValue ?? ""
                if firstToolUseId == nil { firstToolUseId = toolUseId }
                events.append(.toolResult(.init(
                    toolUseId: toolUseId,
                    output: Self.stringify(block["content"]).truncated(maxLength: Self.maximumTextLength),
                    isError: block["is_error"]?.boolValue ?? false
                )))
            case "text":
                let text = block["text"]?.stringValue ?? ""
                if text.hasPrefix("[Request interrupted by user") {
                    events.append(.systemNotice(.init(kind: "interrupted", level: .warning, text: "Interrupted.")))
                }
            default:
                continue
            }
        }
        if let toolUseId = firstToolUseId, let edit = Self.fileEdit(from: value["tool_use_result"], toolUseId: toolUseId) {
            events.append(.fileEdit(edit))
        }
        return events
    }

    /// Flattens tool-result content (string or content blocks) to text.
    static func stringify(_ content: JSONValue?) -> String {
        guard let content else { return "" }
        if let string = content.stringValue {
            return stripToolUseError(string)
        }
        let parts = (content.arrayValue ?? []).compactMap { block -> String? in
            switch block["type"]?.stringValue {
            case "text": block["text"]?.stringValue
            case "image": "[image]"
            default: nil
            }
        }
        return stripToolUseError(parts.joined(separator: "\n"))
    }

    private static func stripToolUseError(_ text: String) -> String {
        text.replacingOccurrences(of: "<tool_use_error>", with: "")
            .replacingOccurrences(of: "</tool_use_error>", with: "")
    }

    /// Builds a unified diff from the CLI's `tool_use_result` for Edit/Write.
    static func fileEdit(from result: JSONValue?, toolUseId: String) -> SessionEvent.FileEdit? {
        guard let result, let path = result["filePath"]?.stringValue else { return nil }
        if let hunks = result["structuredPatch"]?.arrayValue, !hunks.isEmpty {
            let diff = hunks.map { hunk -> String in
                let header = "@@ -\(hunk["oldStart"]?.intValue ?? 0),\(hunk["oldLines"]?.intValue ?? 0) +\(hunk["newStart"]?.intValue ?? 0),\(hunk["newLines"]?.intValue ?? 0) @@"
                let lines = (hunk["lines"]?.arrayValue ?? []).compactMap(\.stringValue)
                return ([header] + lines).joined(separator: "\n")
            }.joined(separator: "\n")
            let kind: SessionEvent.FileEdit.Kind = result["type"]?.stringValue == "create" ? .created : .modified
            return SessionEvent.FileEdit(toolUseId: toolUseId, path: path, kind: kind, diff: diff.truncated(maxLength: maximumTextLength))
        }
        if result["type"]?.stringValue == "create", let content = result["content"]?.stringValue {
            var lines = content.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            let diff = (["@@ -0,0 +1,\(lines.count) @@"] + lines.map { "+\($0)" }).joined(separator: "\n")
            return SessionEvent.FileEdit(toolUseId: toolUseId, path: path, kind: .created, diff: diff.truncated(maxLength: maximumTextLength))
        }
        return nil
    }

    // MARK: result

    private mutating func result(_ value: JSONValue) -> [SessionEvent] {
        streamingText.removeAll()
        let usage = value["usage"].map { usage in
            SessionEvent.Usage(
                inputTokens: usage["input_tokens"]?.intValue ?? 0,
                outputTokens: usage["output_tokens"]?.intValue ?? 0,
                cacheReadInputTokens: usage["cache_read_input_tokens"]?.intValue ?? 0,
                cacheCreationInputTokens: usage["cache_creation_input_tokens"]?.intValue ?? 0
            )
        }
        let isError = value["is_error"]?.boolValue ?? false
        let text = value["result"]?.stringValue
        var events: [SessionEvent] = []
        if isError, let text, Self.looksLikeLoginProblem(text) {
            events.append(Self.loginRequiredNotice)
        }
        events.append(.result(SessionEvent.TurnResult(
            isError: isError,
            subtype: value["subtype"]?.stringValue ?? (isError ? "error" : "success"),
            durationMs: value["duration_ms"]?.intValue ?? 0,
            numTurns: value["num_turns"]?.intValue,
            costUSD: value["total_cost_usd"]?.doubleValue,
            usage: usage,
            text: text?.truncated(maxLength: Self.maximumTextLength)
        )))
        return events
    }

    private func rateLimit(_ value: JSONValue) -> [SessionEvent] {
        guard let info = value["rate_limit_info"], let status = info["status"]?.stringValue, status != "allowed" else { return [] }
        var text = "Claude usage limit reached."
        if let resets = info["resetsAt"]?.doubleValue {
            let date = Date(timeIntervalSince1970: resets)
            text += " It resets at \(date.formatted(date: .omitted, time: .shortened))."
        }
        return [.systemNotice(.init(kind: "rateLimited", level: .warning, text: text))]
    }

    static func looksLikeLoginProblem(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("/login") || lower.contains("invalid api key") || lower.contains("not logged in")
            || lower.contains("authentication_error") || lower.contains("oauth token has expired")
    }
}
