import Foundation
import PilothouseKit

/// An approval the agent asked for over its own stdio protocol (Codex, Gemini).
/// Claude Code asks through the MCP permission endpoint instead.
public struct AgentPermissionRequest: Sendable, Hashable {
    /// JSON-RPC id to answer.
    public var rpcId: JSONValue
    /// Tool name in Remote Code's vocabulary (`Bash`, `Edit`, …) for the phone.
    public var tool: String
    public var input: JSONValue
    public var toolUseId: String?
    /// Protocol-specific data the reply needs (e.g. ACP option IDs).
    public var context: JSONValue

    public init(rpcId: JSONValue, tool: String, input: JSONValue, toolUseId: String? = nil, context: JSONValue = .null) {
        self.rpcId = rpcId
        self.tool = tool
        self.input = input
        self.toolUseId = toolUseId
        self.context = context
    }
}

/// Everything an adapter wants done after reading one line of agent output.
public struct AgentOutput: Sendable {
    public var events: [SessionEvent] = []
    /// Lines to write to the agent's stdin (replies, queued requests).
    public var writes: [Data] = []
    public var permissionRequests: [AgentPermissionRequest] = []
    /// Sub-agent thread the events belong to (Claude `Task` sub-agents).
    public var thread: String?
    /// Usage limits the CLI reported with this line.
    public var usageLimits: UsageLimits?

    public init(
        events: [SessionEvent] = [], writes: [Data] = [], permissionRequests: [AgentPermissionRequest] = [], thread: String? = nil
    ) {
        self.events = events
        self.writes = writes
        self.permissionRequests = permissionRequests
        self.thread = thread
    }
}

/// Speaks one agent CLI's stdio protocol for `SessionManager`.
///
/// One adapter lives as long as one CLI process. `SessionManager` keeps owning
/// the process (spawn, retire, exit handling, D-005); the adapter only turns
/// output lines into `SessionEvent`s and user input into lines to write.
public protocol AgentAdapter: Sendable {
    /// Lines to write right after the process started (handshakes).
    mutating func startupLines() -> [Data]
    /// Parses one stdout line.
    mutating func consume(line: String) -> AgentOutput
    /// Lines that send a user message. May return nothing and send later
    /// (via `consume(line:).writes`) when the agent is not ready yet.
    mutating func userMessageLines(text: String, attachments: [MessageAttachment]) throws -> [Data]
    /// Lines that stop the running turn, or `nil` to interrupt with SIGINT and
    /// let the process retire (Claude Code, D-002).
    mutating func interruptLines() -> [Data]?
    /// The answer to an approval request from `consume(line:)`.
    func permissionReply(to request: AgentPermissionRequest, allow: Bool) -> Data?
    /// Text of blocks that are still streaming, by block ID.
    var streamingText: [String: String] { get }
}

/// Claude Code `stream-json`: the original Remote Code protocol.
public struct ClaudeAdapter: AgentAdapter {
    private var normalizer = StreamJSONNormalizer()

    public init() {}

    public mutating func startupLines() -> [Data] { [] }

    public mutating func consume(line: String) -> AgentOutput {
        let (thread, events) = normalizer.consumeThreaded(line: line)
        var output = AgentOutput(events: events, thread: thread)
        if line.contains("\"rate_limit_event\""), let value = JSONRPC.parse(line) {
            output.usageLimits = UsageLimitParser.claude(value)
        }
        return output
    }

    public mutating func userMessageLines(text: String, attachments: [MessageAttachment]) throws -> [Data] {
        [try ClaudeCommand.userMessageLine(text: text, attachments: attachments)]
    }

    public mutating func interruptLines() -> [Data]? { nil }

    public func permissionReply(to request: AgentPermissionRequest, allow: Bool) -> Data? { nil }

    public var streamingText: [String: String] { normalizer.streamingText }
}

/// JSON-RPC 2.0 framing shared by the Codex and ACP adapters (one object per line).
enum JSONRPC {
    static func request(id: Int, method: String, params: JSONValue) -> Data {
        line(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
    }

    static func notification(method: String, params: JSONValue = .null) -> Data {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if !params.isNull { message["params"] = params }
        return line(.object(message))
    }

    static func result(id: JSONValue, _ result: JSONValue) -> Data {
        line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(id: JSONValue, code: Int, message: String) -> Data {
        line(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    static func line(_ value: JSONValue) -> Data {
        Data((value.jsonString() + "\n").utf8)
    }

    /// Parses a line; `nil` for anything that is not a JSON object.
    static func parse(_ line: String) -> JSONValue? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let value = try? JSONValue.parse(trimmed) else { return nil }
        return value
    }

    /// Truncates long text the same way the Claude normalizer does.
    static func clip(_ text: String) -> String {
        let limit = StreamJSONNormalizer.maximumTextLength
        return text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }
}
