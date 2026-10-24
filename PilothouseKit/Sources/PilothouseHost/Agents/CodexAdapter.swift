import Foundation
import PilothouseKit

/// Drives `codex app-server` (JSON-RPC 2.0 over stdio, protocol v2).
///
/// Verified against Codex CLI 0.162.1 (fixture `codex-app-server.jsonl`):
///
/// * startup: `initialize` → `initialized` → `thread/start` (or `thread/resume`)
/// * input: `turn/start { threadId, input }`; stop: `turn/interrupt`
/// * `item/agentMessage/delta` → ephemeral text; `item/completed agentMessage` → message
/// * `commandExecution` / `fileChange` / `mcpToolCall` items → tool use + result (+ diffs)
/// * `item/commandExecution|fileChange/requestApproval` → phone approval
/// * `turn/completed` → result
///
/// Unknown notifications are ignored and unknown server requests are answered
/// with a JSON-RPC error, so newer Codex versions degrade gracefully.
public struct CodexAdapter: AgentAdapter {
    public struct Options: Sendable, Equatable {
        public var workingDirectory: String
        public var model: String?
        public var permissionMode: PermissionMode
        /// Codex thread to resume, if the conversation exists already.
        public var threadId: String?
        /// Extra instructions (used for delegated sub-agent runs).
        public var developerInstructions: String?

        public init(
            workingDirectory: String, model: String?, permissionMode: PermissionMode, threadId: String?,
            developerInstructions: String? = nil
        ) {
            self.workingDirectory = workingDirectory
            self.model = model
            self.permissionMode = permissionMode
            self.threadId = threadId
            self.developerInstructions = developerInstructions
        }
    }

    public private(set) var threadId: String?
    public private(set) var activeTurnId: String?
    public private(set) var streamingText: [String: String] = [:]

    private let options: Options
    private var nextId = 0
    /// Method of every request we sent, by id.
    private var sentRequests: [Int: String] = [:]
    /// User inputs waiting for the thread to exist.
    private var queuedInputs: [JSONValue] = []
    private var reasoning: [String: String] = [:]
    /// File paths of `fileChange` items, for approval prompts.
    private var fileChanges: [String: [JSONValue]] = [:]
    private var turnStartedAt: Date?
    private var usageAtTurnStart: SessionEvent.Usage?
    private var lastUsage: SessionEvent.Usage?

    public init(options: Options) {
        self.options = options
    }

    // MARK: AgentAdapter

    public mutating func startupLines() -> [Data] {
        let client: JSONValue = ["clientInfo": ["name": "pilothouse", "title": "Pilothouse", "version": "1.1"], "capabilities": nil]
        var lines = [request("initialize", client), JSONRPC.notification(method: "initialized")]
        if let threadId = options.threadId {
            lines.append(request("thread/resume", threadParameters(resuming: threadId)))
        } else {
            lines.append(request("thread/start", threadParameters(resuming: nil)))
        }
        return lines
    }

    public mutating func consume(line: String) -> AgentOutput {
        guard let message = JSONRPC.parse(line) else { return AgentOutput() }
        let method = message["method"]?.stringValue
        let id = message["id"]
        switch (method, id) {
        case (let method?, let id?) where !id.isNull:
            return serverRequest(method, id: id, params: message["params"] ?? .null)
        case (let method?, _):
            return notification(method, params: message["params"] ?? .null)
        case (nil, let id?):
            return response(id: id.intValue ?? -1, message: message)
        default:
            return AgentOutput()
        }
    }

    public mutating func userMessageLines(text: String, attachments: [MessageAttachment]) throws -> [Data] {
        var input: [JSONValue] = attachments.map { attachment in
            ["type": "image", "url": .string("data:\(attachment.mediaType);base64,\(attachment.data.base64EncodedString())")]
        }
        if !text.isEmpty {
            input.append(["type": "text", "text": .string(text), "text_elements": []])
        }
        guard let threadId else {
            queuedInputs.append(.array(input))
            return []
        }
        return [request("turn/start", ["threadId": .string(threadId), "input": .array(input)])]
    }

    public mutating func interruptLines() -> [Data]? {
        guard let threadId, let activeTurnId else { return [] }
        return [request("turn/interrupt", ["threadId": .string(threadId), "turnId": .string(activeTurnId)])]
    }

    public func permissionReply(to request: AgentPermissionRequest, allow: Bool) -> Data? {
        let method = request.context["method"]?.stringValue ?? ""
        if method == "applyPatchApproval" || method == "execCommandApproval" {
            return JSONRPC.result(id: request.rpcId, ["decision": .string(allow ? "approved" : "denied")])
        }
        return JSONRPC.result(id: request.rpcId, ["decision": .string(allow ? "accept" : "decline")])
    }

    // MARK: Requests

    private mutating func request(_ method: String, _ params: JSONValue) -> Data {
        nextId += 1
        sentRequests[nextId] = method
        return JSONRPC.request(id: nextId, method: method, params: params)
    }

    /// Maps Pilothouse permission modes onto Codex approval policy + sandbox.
    static func policy(for mode: PermissionMode) -> (approval: String, sandbox: String) {
        switch mode {
        case .acceptEdits: ("on-request", "workspace-write")
        case .bypassPermissions: ("never", "danger-full-access")
        case .plan: ("on-request", "read-only")
        default: ("untrusted", "read-only")
        }
    }

    static let planInstructions = "You are in plan mode: analyse and propose a plan, but do not modify files or run commands that change anything."

    private func threadParameters(resuming threadId: String?) -> JSONValue {
        let policy = Self.policy(for: options.permissionMode)
        var params: [String: JSONValue] = [
            "cwd": .string(options.workingDirectory),
            "approvalPolicy": .string(policy.approval),
            "sandbox": .string(policy.sandbox),
        ]
        if let threadId { params["threadId"] = .string(threadId) }
        if let model = options.model, !model.isEmpty { params["model"] = .string(model) }
        let instructions = [options.permissionMode == .plan ? Self.planInstructions : nil, options.developerInstructions]
            .compactMap { $0 }
        if !instructions.isEmpty { params["developerInstructions"] = .string(instructions.joined(separator: "\n\n")) }
        return .object(params)
    }

    // MARK: Responses

    private mutating func response(id: Int, message: JSONValue) -> AgentOutput {
        let method = sentRequests.removeValue(forKey: id)
        var output = AgentOutput()
        if let error = message["error"] {
            let text = error["message"]?.stringValue ?? "Unknown error"
            switch method {
            case "thread/resume":
                // The rollout is gone: start a fresh thread in the same session.
                output.events.append(.systemNotice(.init(
                    kind: "resumeFailed", level: .warning,
                    text: "Codex could not find the earlier conversation. Your next message starts a fresh one in this session."
                )))
                output.writes.append(request("thread/start", threadParameters(resuming: nil)))
            case "turn/start":
                output.events.append(.systemNotice(.init(kind: "turnFailed", level: .error, text: "Codex: \(text)")))
                output.events.append(.result(.init(isError: true, subtype: "error", durationMs: 0, text: text)))
            case "initialize", "thread/start":
                output.events.append(Self.notice(for: text))
            default:
                break
            }
            return output
        }
        let result = message["result"] ?? .null
        switch method {
        case "thread/start", "thread/resume":
            let thread = result["thread"] ?? .null
            threadId = thread["id"]?.stringValue ?? threadId
            if let threadId {
                output.events.append(.sessionInfo(.init(
                    claudeSessionId: threadId,
                    model: result["model"]?.stringValue,
                    permissionMode: options.permissionMode.rawValue,
                    cwd: options.workingDirectory,
                    claudeVersion: nil
                )))
                for input in queuedInputs {
                    output.writes.append(request("turn/start", ["threadId": .string(threadId), "input": input]))
                }
                queuedInputs.removeAll()
            }
        case "turn/start":
            activeTurnId = result["turn"]?["id"]?.stringValue ?? activeTurnId
        default:
            break
        }
        return output
    }

    static func notice(for error: String) -> SessionEvent {
        let lower = error.lowercased()
        if lower.contains("login") || lower.contains("auth") || lower.contains("401") {
            return .systemNotice(.init(
                kind: "loginRequired", level: .error,
                text: "Codex is not signed in on the Mac. Run `codex login` in Terminal there."
            ))
        }
        return .systemNotice(.init(kind: "agentError", level: .error, text: "Codex: \(error)"))
    }

    // MARK: Server requests (approvals)

    private mutating func serverRequest(_ method: String, id: JSONValue, params: JSONValue) -> AgentOutput {
        let itemId = params["itemId"]?.stringValue
        let context: JSONValue = ["method": .string(method)]
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            var input: [String: JSONValue] = ["command": .string(Self.displayCommand(params))]
            if let reason = params["reason"]?.stringValue { input["description"] = .string(reason) }
            return AgentOutput(permissionRequests: [AgentPermissionRequest(
                rpcId: id, tool: "Bash", input: .object(input), toolUseId: itemId, context: context
            )])
        case "item/fileChange/requestApproval", "applyPatchApproval":
            let changes = itemId.flatMap { fileChanges[$0] } ?? []
            var input: [String: JSONValue] = [:]
            if let first = changes.first?["path"] { input["file_path"] = first }
            if changes.count > 1 { input["files"] = .array(changes.compactMap { $0["path"] }) }
            if let reason = params["reason"]?.stringValue { input["description"] = .string(reason) }
            if let grantRoot = params["grantRoot"]?.stringValue { input["grant_root"] = .string(grantRoot) }
            return AgentOutput(permissionRequests: [AgentPermissionRequest(
                rpcId: id, tool: "Edit", input: .object(input), toolUseId: itemId, context: context
            )])
        default:
            return AgentOutput(writes: [JSONRPC.error(id: id, code: -32601, message: "Pilothouse does not support \(method)")])
        }
    }

    /// `/bin/zsh -lc "ls -la"` → `ls -la` when Codex parsed it.
    static func displayCommand(_ value: JSONValue) -> String {
        if let actions = value["commandActions"]?.arrayValue, actions.count == 1, let command = actions[0]["command"]?.stringValue {
            return command
        }
        return value["command"]?.stringValue ?? ""
    }

    // MARK: Notifications

    private mutating func notification(_ method: String, params: JSONValue) -> AgentOutput {
        switch method {
        case "turn/started":
            activeTurnId = params["turn"]?["id"]?.stringValue ?? activeTurnId
            turnStartedAt = Date()
            usageAtTurnStart = lastUsage
            return AgentOutput()
        case "item/agentMessage/delta":
            guard let itemId = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue else { return AgentOutput() }
            streamingText[itemId, default: ""] += delta
            return AgentOutput(events: [.assistantTextDelta(.init(blockId: itemId, text: delta))])
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            guard let itemId = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue else { return AgentOutput() }
            reasoning[itemId, default: ""] += delta
            return AgentOutput(events: [.thinking(.init(blockId: itemId, text: reasoning[itemId] ?? "", isComplete: false))])
        case "item/started":
            return AgentOutput(events: itemStarted(params["item"] ?? .null))
        case "item/completed":
            return AgentOutput(events: itemCompleted(params["item"] ?? .null))
        case "thread/tokenUsage/updated":
            let total = params["tokenUsage"]?["total"] ?? .null
            lastUsage = SessionEvent.Usage(
                inputTokens: total["inputTokens"]?.intValue ?? 0,
                outputTokens: total["outputTokens"]?.intValue ?? 0,
                cacheReadInputTokens: total["cachedInputTokens"]?.intValue ?? 0
            )
            return AgentOutput()
        case "turn/completed":
            return AgentOutput(events: turnCompleted(params["turn"] ?? .null))
        case "error":
            let text = params["error"]?["message"]?.stringValue ?? "Unknown error"
            if params["willRetry"]?.boolValue == true {
                return AgentOutput(events: [.systemNotice(.init(kind: "apiRetry", level: .warning, text: "Codex: \(text) Retrying…"))])
            }
            return AgentOutput(events: [Self.notice(for: text)])
        case "account/rateLimits/updated":
            var output = AgentOutput()
            output.usageLimits = UsageLimitParser.codex(params, source: .lastTurn)
            return output
        case "thread/compacted":
            return AgentOutput(events: [.systemNotice(.init(kind: "compacted", level: .info, text: "The conversation was compacted to free up context."))])
        default:
            return AgentOutput()
        }
    }

    private mutating func itemStarted(_ item: JSONValue) -> [SessionEvent] {
        guard let id = item["id"]?.stringValue else { return [] }
        switch item["type"]?.stringValue {
        case "commandExecution":
            return [.toolUse(.init(toolUseId: id, name: "Bash", input: ["command": .string(Self.displayCommand(item))]))]
        case "fileChange":
            let changes = item["changes"]?.arrayValue ?? []
            fileChanges[id] = changes
            return [.toolUse(.init(toolUseId: id, name: changes.count == 1 ? "Edit" : "MultiEdit", input: Self.fileInput(changes)))]
        case "mcpToolCall":
            let server = item["server"]?.stringValue ?? "mcp"
            let tool = item["tool"]?.stringValue ?? "tool"
            return [.toolUse(.init(toolUseId: id, name: "mcp__\(server)__\(tool)", input: item["arguments"] ?? .null))]
        case "webSearch":
            return [.toolUse(.init(toolUseId: id, name: "WebSearch", input: ["query": item["query"] ?? ""]))]
        default:
            return []
        }
    }

    private mutating func itemCompleted(_ item: JSONValue) -> [SessionEvent] {
        guard let id = item["id"]?.stringValue else { return [] }
        let status = item["status"]?.stringValue
        let failed = status == "failed" || status == "declined"
        switch item["type"]?.stringValue {
        case "agentMessage":
            streamingText.removeValue(forKey: id)
            let text = item["text"]?.stringValue ?? ""
            return text.isEmpty ? [] : [.assistantMessage(.init(blockId: id, text: text))]
        case "reasoning":
            let summary = (item["summary"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n\n")
            let text = summary.isEmpty ? (reasoning[id] ?? "") : summary
            reasoning.removeValue(forKey: id)
            return text.isEmpty ? [] : [.thinking(.init(blockId: id, text: text, isComplete: true))]
        case "commandExecution":
            let exitCode = item["exitCode"]?.intValue
            var output = item["aggregatedOutput"]?.stringValue ?? ""
            if status == "declined" { output = "The user denied this command." }
            return [.toolResult(.init(toolUseId: id, output: JSONRPC.clip(output), isError: failed || (exitCode ?? 0) != 0))]
        case "fileChange":
            fileChanges.removeValue(forKey: id)
            var events: [SessionEvent] = []
            if !failed {
                for change in item["changes"]?.arrayValue ?? [] {
                    let kind: SessionEvent.FileEdit.Kind = change["kind"]?["type"]?.stringValue == "add" ? .created : .modified
                    events.append(.fileEdit(.init(
                        toolUseId: id, path: change["path"]?.stringValue ?? "", kind: kind,
                        diff: JSONRPC.clip(change["diff"]?.stringValue ?? "")
                    )))
                }
            }
            let text = status == "declined" ? "The user denied this change." : (failed ? "The change could not be applied." : "Applied.")
            events.append(.toolResult(.init(toolUseId: id, output: text, isError: failed)))
            return events
        case "mcpToolCall":
            let error = item["error"]?["message"]?.stringValue
            let content = item["result"]?["content"]
            let text = error ?? content.map(StreamJSONNormalizer.stringify) ?? ""
            return [.toolResult(.init(toolUseId: id, output: JSONRPC.clip(text), isError: error != nil || failed))]
        case "webSearch":
            return [.toolResult(.init(toolUseId: id, output: "", isError: false))]
        default:
            return []
        }
    }

    static func fileInput(_ changes: [JSONValue]) -> JSONValue {
        var input: [String: JSONValue] = [:]
        if let first = changes.first?["path"] { input["file_path"] = first }
        if changes.count > 1 { input["files"] = .array(changes.compactMap { $0["path"] }) }
        return .object(input)
    }

    private mutating func turnCompleted(_ turn: JSONValue) -> [SessionEvent] {
        activeTurnId = nil
        let status = turn["status"]?.stringValue ?? "completed"
        let duration = turn["durationMs"]?.intValue
            ?? turnStartedAt.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? 0
        turnStartedAt = nil
        var usage = lastUsage
        if let total = lastUsage, let start = usageAtTurnStart {
            usage = SessionEvent.Usage(
                inputTokens: total.inputTokens - start.inputTokens,
                outputTokens: total.outputTokens - start.outputTokens,
                cacheReadInputTokens: total.cacheReadInputTokens - start.cacheReadInputTokens
            )
        }
        var events: [SessionEvent] = []
        if status == "interrupted" {
            events.append(.systemNotice(.init(kind: "interrupted", level: .warning, text: "Interrupted.")))
        }
        let errorText = turn["error"]?["message"]?.stringValue
        if let errorText, status == "failed" {
            events.append(Self.notice(for: errorText))
        }
        events.append(.result(.init(
            isError: status == "failed", subtype: status == "completed" ? "success" : status,
            durationMs: duration, usage: usage, text: errorText
        )))
        return events
    }
}
