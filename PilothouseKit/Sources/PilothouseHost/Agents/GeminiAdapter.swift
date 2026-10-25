import Foundation
import PilothouseKit

/// Drives `gemini --experimental-acp` (Agent Client Protocol v1, JSON-RPC over stdio).
///
/// Written against ACP v1 as implemented by Gemini CLI 0.24.0:
///
/// * startup: `initialize` → `authenticate` → `session/new` (or `session/load`
///   when the agent supports `loadSession`; 0.24.0 does not)
/// * input: `session/prompt`, whose response ends the turn; stop: `session/cancel`
/// * `session/update` chunks → text, thoughts, tool calls (+ diffs)
/// * `session/request_permission` → phone approval
///
/// The Mac does not offer ACP file-system or terminal capabilities, so the
/// agent uses its own tools and asks for permission before side effects.
public struct GeminiAdapter: AgentAdapter {
    public struct Options: Sendable, Equatable {
        public var workingDirectory: String
        public var model: String?
        public var permissionMode: PermissionMode
        /// ACP session to load, if the agent supports it.
        public var sessionId: String?
        /// `gemini-api-key` when a key is in the environment, else `oauth-personal`.
        public var authMethod: String

        public init(workingDirectory: String, model: String?, permissionMode: PermissionMode, sessionId: String?, authMethod: String) {
            self.workingDirectory = workingDirectory
            self.model = model
            self.permissionMode = permissionMode
            self.sessionId = sessionId
            self.authMethod = authMethod
        }
    }

    public private(set) var sessionId: String?
    public private(set) var streamingText: [String: String] = [:]
    public private(set) var isPrompting = false

    private let options: Options
    private var nextId = 0
    private var sentRequests: [Int: String] = [:]
    private var queuedPrompts: [JSONValue] = []
    private var canLoadSession = false
    private var messageCounter = 0
    private var currentMessageId: String?
    private var currentThoughtId: String?
    private var thoughtText = ""
    private var toolNames: [String: String] = [:]
    private var promptStartedAt: Date?

    public init(options: Options) {
        self.options = options
    }

    // MARK: AgentAdapter

    public mutating func startupLines() -> [Data] {
        [request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
        ])]
    }

    public mutating func consume(line: String) -> AgentOutput {
        guard let message = JSONRPC.parse(line) else { return AgentOutput() }
        let method = message["method"]?.stringValue
        let id = message["id"]
        switch (method, id) {
        case (let method?, let id?) where !id.isNull:
            return serverRequest(method, id: id, params: message["params"] ?? .null)
        case ("session/update"?, _):
            return AgentOutput(events: update(message["params"]?["update"] ?? .null))
        case (nil, let id?):
            return response(id: id.intValue ?? -1, message: message)
        default:
            return AgentOutput()
        }
    }

    public mutating func userMessageLines(text: String, attachments: [MessageAttachment]) throws -> [Data] {
        var prompt: [JSONValue] = attachments.map { attachment in
            ["type": "image", "mimeType": .string(attachment.mediaType), "data": .string(attachment.data.base64EncodedString())]
        }
        if !text.isEmpty { prompt.append(["type": "text", "text": .string(text)]) }
        guard let sessionId else {
            queuedPrompts.append(.array(prompt))
            return []
        }
        return [promptRequest(sessionId: sessionId, prompt: .array(prompt))]
    }

    public mutating func interruptLines() -> [Data]? {
        guard let sessionId, isPrompting else { return [] }
        return [JSONRPC.notification(method: "session/cancel", params: ["sessionId": .string(sessionId)])]
    }

    public func permissionReply(to request: AgentPermissionRequest, allow: Bool) -> Data? {
        let options = request.context["options"]?.arrayValue ?? []
        let wanted = allow ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        guard let option = wanted.lazy.compactMap({ kind in options.first { $0["kind"]?.stringValue == kind } }).first,
            let optionId = option["optionId"]
        else {
            return JSONRPC.result(id: request.rpcId, ["outcome": ["outcome": "cancelled"]])
        }
        return JSONRPC.result(id: request.rpcId, ["outcome": ["outcome": "selected", "optionId": optionId]])
    }

    // MARK: Requests

    private mutating func request(_ method: String, _ params: JSONValue) -> Data {
        nextId += 1
        sentRequests[nextId] = method
        return JSONRPC.request(id: nextId, method: method, params: params)
    }

    private mutating func promptRequest(sessionId: String, prompt: JSONValue) -> Data {
        isPrompting = true
        promptStartedAt = Date()
        return request("session/prompt", ["sessionId": .string(sessionId), "prompt": prompt])
    }

    private mutating func openSession() -> Data {
        if canLoadSession, let previous = options.sessionId {
            return request("session/load", [
                "sessionId": .string(previous), "cwd": .string(options.workingDirectory), "mcpServers": [],
            ])
        }
        return request("session/new", ["cwd": .string(options.workingDirectory), "mcpServers": []])
    }

    // MARK: Responses

    private mutating func response(id: Int, message: JSONValue) -> AgentOutput {
        let method = sentRequests.removeValue(forKey: id)
        var output = AgentOutput()
        if let error = message["error"] {
            let details = error["data"]?["details"]?.stringValue ?? error["message"]?.stringValue ?? "Unknown error"
            switch method {
            case "authenticate", "session/new", "session/load", "initialize":
                output.events.append(Self.loginNotice(details))
            case "session/prompt":
                isPrompting = false
                output.events += finishBlocks()
                output.events.append(.systemNotice(.init(kind: "agentError", level: .error, text: "Gemini: \(details)")))
                output.events.append(.result(.init(isError: true, subtype: "error", durationMs: elapsed(), text: details)))
            default:
                break
            }
            return output
        }
        let result = message["result"] ?? .null
        switch method {
        case "initialize":
            canLoadSession = result["agentCapabilities"]?["loadSession"]?.boolValue ?? false
            output.writes.append(request("authenticate", ["methodId": .string(options.authMethod)]))
        case "authenticate":
            output.writes.append(openSession())
        case "session/new", "session/load":
            sessionId = result["sessionId"]?.stringValue ?? options.sessionId
            if let sessionId {
                output.events.append(.sessionInfo(.init(
                    claudeSessionId: sessionId, model: options.model, permissionMode: options.permissionMode.rawValue,
                    cwd: options.workingDirectory
                )))
                for prompt in queuedPrompts {
                    output.writes.append(promptRequest(sessionId: sessionId, prompt: prompt))
                }
                queuedPrompts.removeAll()
            }
        case "session/prompt":
            isPrompting = false
            output.events += finishBlocks()
            let reason = result["stopReason"]?.stringValue ?? "end_turn"
            if reason == "cancelled" {
                output.events.append(.systemNotice(.init(kind: "interrupted", level: .warning, text: "Interrupted.")))
            }
            output.events.append(.result(.init(
                isError: reason == "refusal", subtype: reason == "end_turn" ? "success" : reason, durationMs: elapsed()
            )))
        default:
            break
        }
        return output
    }

    private mutating func elapsed() -> Int {
        defer { promptStartedAt = nil }
        return promptStartedAt.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? 0
    }

    static func loginNotice(_ details: String) -> SessionEvent {
        .systemNotice(.init(
            kind: "loginRequired", level: .error,
            text: "Gemini could not sign in: \(details) Run `gemini` once in Terminal on the Mac to sign in."
        ))
    }

    // MARK: Server requests

    private mutating func serverRequest(_ method: String, id: JSONValue, params: JSONValue) -> AgentOutput {
        guard method == "session/request_permission" else {
            return AgentOutput(writes: [JSONRPC.error(id: id, code: -32601, message: "Remote Code does not support \(method)")])
        }
        let toolCall = params["toolCall"] ?? .null
        let toolCallId = toolCall["toolCallId"]?.stringValue
        let (name, input) = Self.tool(from: toolCall, known: toolCallId.flatMap { toolNames[$0] })
        return AgentOutput(permissionRequests: [AgentPermissionRequest(
            rpcId: id, tool: name, input: input, toolUseId: toolCallId, context: ["options": params["options"] ?? []]
        )])
    }

    /// ACP tool kinds → Remote Code tool names (so the phone shows the right card).
    static func tool(from call: JSONValue, known: String? = nil) -> (name: String, input: JSONValue) {
        let raw = call["rawInput"]?.objectValue ?? [:]
        var input = raw
        let path = call["locations"]?[0]?["path"]?.stringValue
        let title = call["title"]?.stringValue ?? ""
        let name: String
        switch call["kind"]?.stringValue {
        case "execute":
            name = "Bash"
            if input["command"] == nil { input["command"] = .string(title) }
        case "edit":
            name = "Edit"
            if let path { input["file_path"] = .string(path) }
        case "delete", "move":
            name = "Bash"
            input["command"] = .string(title)
        case "read":
            name = "Read"
            if let path { input["file_path"] = .string(path) }
        case "search":
            name = "Grep"
            if input["pattern"] == nil { input["pattern"] = .string(title) }
        case "fetch":
            name = "WebFetch"
        default:
            name = known ?? (title.isEmpty ? "Tool" : title)
            if input.isEmpty { input["description"] = .string(title) }
        }
        return (name, .object(input))
    }

    // MARK: Updates

    private mutating func update(_ update: JSONValue) -> [SessionEvent] {
        switch update["sessionUpdate"]?.stringValue {
        case "agent_message_chunk":
            guard let text = update["content"]?["text"]?.stringValue else { return [] }
            var events = finishThought()
            let id = currentMessageId ?? nextBlockId("msg")
            currentMessageId = id
            streamingText[id, default: ""] += text
            events.append(.assistantTextDelta(.init(blockId: id, text: text)))
            return events
        case "agent_thought_chunk":
            guard let text = update["content"]?["text"]?.stringValue else { return [] }
            let id = currentThoughtId ?? nextBlockId("thought")
            currentThoughtId = id
            thoughtText += text
            return [.thinking(.init(blockId: id, text: thoughtText, isComplete: false))]
        case "tool_call":
            var events = finishBlocks()
            guard let id = update["toolCallId"]?.stringValue else { return events }
            let (name, input) = Self.tool(from: update)
            toolNames[id] = name
            events.append(.toolUse(.init(toolUseId: id, name: name, input: input)))
            events += toolProgress(update, id: id)
            return events
        case "tool_call_update":
            guard let id = update["toolCallId"]?.stringValue else { return [] }
            return toolProgress(update, id: id)
        default:
            return []
        }
    }

    /// Diffs and the final output of a tool call, once it completed or failed.
    private mutating func toolProgress(_ update: JSONValue, id: String) -> [SessionEvent] {
        let status = update["status"]?.stringValue
        guard status == "completed" || status == "failed" else { return [] }
        var events: [SessionEvent] = []
        var texts: [String] = []
        for item in update["content"]?.arrayValue ?? [] {
            switch item["type"]?.stringValue {
            case "diff":
                let path = item["path"]?.stringValue ?? ""
                let old = item["oldText"]?.stringValue
                let new = item["newText"]?.stringValue ?? ""
                events.append(.fileEdit(.init(
                    toolUseId: id, path: path, kind: old == nil ? .created : .modified,
                    diff: JSONRPC.clip(Self.unifiedDiff(path: path, old: old ?? "", new: new))
                )))
            case "content":
                if let text = item["content"]?["text"]?.stringValue { texts.append(text) }
            default:
                break
            }
        }
        toolNames.removeValue(forKey: id)
        events.append(.toolResult(.init(toolUseId: id, output: JSONRPC.clip(texts.joined(separator: "\n")), isError: status == "failed")))
        return events
    }

    /// A whole-file replacement diff; ACP only carries old and new text.
    static func unifiedDiff(path: String, old: String, new: String) -> String {
        let oldLines = old.isEmpty ? [] : old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.isEmpty ? [] : new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines = ["--- a/\(path)", "+++ b/\(path)", "@@ -1,\(oldLines.count) +1,\(newLines.count) @@"]
        lines += oldLines.map { "-\($0)" }
        lines += newLines.map { "+\($0)" }
        return lines.joined(separator: "\n")
    }

    private mutating func nextBlockId(_ prefix: String) -> String {
        messageCounter += 1
        return "gemini-\(prefix)-\(messageCounter)"
    }

    private mutating func finishThought() -> [SessionEvent] {
        guard let id = currentThoughtId else { return [] }
        currentThoughtId = nil
        defer { thoughtText = "" }
        return thoughtText.isEmpty ? [] : [.thinking(.init(blockId: id, text: thoughtText, isComplete: true))]
    }

    private mutating func finishBlocks() -> [SessionEvent] {
        var events = finishThought()
        if let id = currentMessageId {
            currentMessageId = nil
            let text = streamingText.removeValue(forKey: id) ?? ""
            if !text.isEmpty { events.append(.assistantMessage(.init(blockId: id, text: text))) }
        }
        return events
    }
}

/// Launches `gemini --experimental-acp` for one session.
public struct GeminiLauncher: AgentLauncher {
    public var executable: String
    public var environment: [String: String]

    public init(executable: String, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    public func launch(_ options: ClaudeLaunchOptions) async throws -> ChildProcess {
        var arguments = ["--experimental-acp"]
        if let model = options.model, !model.isEmpty { arguments += ["--model", model] }
        switch options.permissionMode {
        case .acceptEdits: arguments += ["--approval-mode", "auto_edit"]
        case .bypassPermissions: arguments += ["--approval-mode", "yolo"]
        default: break
        }
        return try ChildProcess.spawn(
            executable: executable, arguments: arguments, environment: environment, workingDirectory: options.workingDirectory
        )
    }

    public func makeAdapter(for options: ClaudeLaunchOptions) -> any AgentAdapter {
        let usesKey = environment["GEMINI_API_KEY"]?.isEmpty == false
        return GeminiAdapter(options: .init(
            workingDirectory: options.workingDirectory, model: options.model, permissionMode: options.permissionMode,
            sessionId: options.resume ? options.agentSessionId : nil,
            authMethod: usesKey ? "gemini-api-key" : "oauth-personal"
        ))
    }
}
