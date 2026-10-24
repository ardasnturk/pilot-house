import Foundation

/// A normalised event in a Claude session, derived from the CLI's stream-json
/// output (see `docs/PROTOCOL.md` §"Session events").
///
/// Wire format: a flat JSON object with a `type` discriminator, e.g.
/// `{"type":"toolUse","toolUseId":"toolu_1","name":"Bash","input":{...}}`.
public enum SessionEvent: Sendable, Hashable, Codable {
    /// A message the user sent (echoed into the log so every device sees history).
    case userMessage(UserMessage)
    /// A chunk of assistant text that is still streaming. **Ephemeral**: never
    /// persisted; the complete text follows as `assistantMessage`.
    case assistantTextDelta(TextDelta)
    /// A complete assistant text block.
    case assistantMessage(AssistantMessage)
    /// Extended-thinking progress (`isComplete == false` is ephemeral).
    case thinking(Thinking)
    /// Claude called a tool.
    case toolUse(ToolUse)
    /// A tool finished.
    case toolResult(ToolResult)
    /// A tool changed a file; carries a unified diff.
    case fileEdit(FileEdit)
    /// A turn finished.
    case result(TurnResult)
    /// Informational, warning or error line from Pilothouse or the CLI.
    case systemNotice(SystemNotice)
    /// Session metadata reported by the CLI at start-up (`system/init`).
    case sessionInfo(SessionInfo)
    /// The outcome of a permission request (kept for the transcript).
    case permissionDecision(PermissionDecision)

    // MARK: Payloads

    public struct UserMessage: Sendable, Hashable, Codable {
        public var text: String
        public var attachmentCount: Int
        public init(text: String, attachmentCount: Int = 0) {
            self.text = text
            self.attachmentCount = attachmentCount
        }
    }

    public struct TextDelta: Sendable, Hashable, Codable {
        /// Identifies the content block: `<api message id>:<block index>`.
        public var blockId: String
        public var text: String
        /// When `true`, `text` is the full text so far and replaces what the
        /// client accumulated (sent to late subscribers mid-stream).
        public var replace: Bool
        public init(blockId: String, text: String, replace: Bool = false) {
            self.blockId = blockId
            self.text = text
            self.replace = replace
        }
    }

    public struct AssistantMessage: Sendable, Hashable, Codable {
        public var blockId: String
        public var text: String
        public init(blockId: String, text: String) {
            self.blockId = blockId
            self.text = text
        }
    }

    public struct Thinking: Sendable, Hashable, Codable {
        public var blockId: String
        public var text: String
        public var isComplete: Bool
        public init(blockId: String, text: String, isComplete: Bool) {
            self.blockId = blockId
            self.text = text
            self.isComplete = isComplete
        }
    }

    public struct ToolUse: Sendable, Hashable, Codable {
        public var toolUseId: String
        public var name: String
        public var input: JSONValue
        public init(toolUseId: String, name: String, input: JSONValue) {
            self.toolUseId = toolUseId
            self.name = name
            self.input = input
        }
    }

    public struct ToolResult: Sendable, Hashable, Codable {
        public var toolUseId: String
        public var output: String
        public var isError: Bool
        public init(toolUseId: String, output: String, isError: Bool) {
            self.toolUseId = toolUseId
            self.output = output
            self.isError = isError
        }
    }

    public struct FileEdit: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Hashable, Codable {
            case created
            case modified
        }
        public var toolUseId: String
        public var path: String
        public var kind: Kind
        /// Unified diff (`@@ -a,b +c,d @@` hunks, lines prefixed with ` `, `-`, `+`).
        public var diff: String
        public init(toolUseId: String, path: String, kind: Kind, diff: String) {
            self.toolUseId = toolUseId
            self.path = path
            self.kind = kind
            self.diff = diff
        }
    }

    public struct TurnResult: Sendable, Hashable, Codable {
        public var isError: Bool
        /// CLI subtype: `success`, `error_during_execution`, `error_max_turns`, …
        public var subtype: String
        public var durationMs: Int
        public var numTurns: Int?
        public var costUSD: Double?
        public var usage: Usage?
        public var text: String?
        public init(
            isError: Bool, subtype: String, durationMs: Int, numTurns: Int? = nil,
            costUSD: Double? = nil, usage: Usage? = nil, text: String? = nil
        ) {
            self.isError = isError
            self.subtype = subtype
            self.durationMs = durationMs
            self.numTurns = numTurns
            self.costUSD = costUSD
            self.usage = usage
            self.text = text
        }
    }

    public struct Usage: Sendable, Hashable, Codable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadInputTokens: Int
        public var cacheCreationInputTokens: Int
        public init(inputTokens: Int, outputTokens: Int, cacheReadInputTokens: Int = 0, cacheCreationInputTokens: Int = 0) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
        }
    }

    public struct SystemNotice: Sendable, Hashable, Codable {
        public enum Level: String, Sendable, Hashable, Codable {
            case info
            case warning
            case error
        }
        /// Stable machine-readable kind, e.g. `interrupted`, `apiRetry`,
        /// `processExited`, `loginRequired`, `compacted`.
        public var kind: String
        public var level: Level
        public var text: String
        public init(kind: String, level: Level, text: String) {
            self.kind = kind
            self.level = level
            self.text = text
        }
    }

    public struct SessionInfo: Sendable, Hashable, Codable {
        public var claudeSessionId: String
        public var model: String?
        public var permissionMode: String?
        public var cwd: String?
        public var claudeVersion: String?
        public var slashCommands: [String]
        public init(
            claudeSessionId: String, model: String? = nil, permissionMode: String? = nil, cwd: String? = nil,
            claudeVersion: String? = nil, slashCommands: [String] = []
        ) {
            self.claudeSessionId = claudeSessionId
            self.model = model
            self.permissionMode = permissionMode
            self.cwd = cwd
            self.claudeVersion = claudeVersion
            self.slashCommands = slashCommands
        }
    }

    public struct PermissionDecision: Sendable, Hashable, Codable {
        public enum Outcome: String, Sendable, Hashable, Codable {
            case allowed
            case allowedForSession
            case denied
            case timedOut
            case cancelled
        }
        public var requestId: String
        public var toolName: String
        public var summary: String
        public var outcome: Outcome
        public init(requestId: String, toolName: String, summary: String, outcome: Outcome) {
            self.requestId = requestId
            self.toolName = toolName
            self.summary = summary
            self.outcome = outcome
        }
    }

    // MARK: Classification

    /// Ephemeral events are broadcast live but never written to the event log
    /// and never consume a sequence number.
    public var isEphemeral: Bool {
        switch self {
        case .assistantTextDelta: true
        case .thinking(let thinking): !thinking.isComplete
        default: false
        }
    }

    /// Stable discriminator used on the wire.
    public var typeName: String {
        switch self {
        case .userMessage: "userMessage"
        case .assistantTextDelta: "assistantTextDelta"
        case .assistantMessage: "assistantMessage"
        case .thinking: "thinking"
        case .toolUse: "toolUse"
        case .toolResult: "toolResult"
        case .fileEdit: "fileEdit"
        case .result: "result"
        case .systemNotice: "systemNotice"
        case .sessionInfo: "sessionInfo"
        case .permissionDecision: "permissionDecision"
        }
    }

    // MARK: Codable

    private enum TypeKey: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "userMessage": self = .userMessage(try UserMessage(from: decoder))
        case "assistantTextDelta": self = .assistantTextDelta(try TextDelta(from: decoder))
        case "assistantMessage": self = .assistantMessage(try AssistantMessage(from: decoder))
        case "thinking": self = .thinking(try Thinking(from: decoder))
        case "toolUse": self = .toolUse(try ToolUse(from: decoder))
        case "toolResult": self = .toolResult(try ToolResult(from: decoder))
        case "fileEdit": self = .fileEdit(try FileEdit(from: decoder))
        case "result": self = .result(try TurnResult(from: decoder))
        case "systemNotice": self = .systemNotice(try SystemNotice(from: decoder))
        case "sessionInfo": self = .sessionInfo(try SessionInfo(from: decoder))
        case "permissionDecision": self = .permissionDecision(try PermissionDecision(from: decoder))
        default:
            // Forward compatibility: an older client shows unknown events as a notice.
            self = .systemNotice(SystemNotice(kind: "unknownEvent", level: .info, text: "Unsupported event: \(type)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(typeName, forKey: .type)
        switch self {
        case .userMessage(let payload): try payload.encode(to: encoder)
        case .assistantTextDelta(let payload): try payload.encode(to: encoder)
        case .assistantMessage(let payload): try payload.encode(to: encoder)
        case .thinking(let payload): try payload.encode(to: encoder)
        case .toolUse(let payload): try payload.encode(to: encoder)
        case .toolResult(let payload): try payload.encode(to: encoder)
        case .fileEdit(let payload): try payload.encode(to: encoder)
        case .result(let payload): try payload.encode(to: encoder)
        case .systemNotice(let payload): try payload.encode(to: encoder)
        case .sessionInfo(let payload): try payload.encode(to: encoder)
        case .permissionDecision(let payload): try payload.encode(to: encoder)
        }
    }
}

/// A persisted session event with its sequence number.
public struct SequencedEvent: Sendable, Hashable, Codable {
    /// 1-based, strictly increasing per session. Ephemeral events carry the
    /// sequence number of the last persisted event and `ephemeral == true`.
    public var seq: Int
    public var timestamp: Date
    public var ephemeral: Bool
    public var event: SessionEvent
    /// The sub-agent this event belongs to: the tool-use ID of the `Task` or
    /// `delegate_to_agent` call that started it. `nil` for the main conversation.
    public var thread: String?

    public init(seq: Int, timestamp: Date, ephemeral: Bool = false, event: SessionEvent, thread: String? = nil) {
        self.seq = seq
        self.timestamp = timestamp
        self.ephemeral = ephemeral
        self.event = event
        self.thread = thread
    }

    private enum CodingKeys: String, CodingKey {
        case seq
        case timestamp = "ts"
        case ephemeral
        case event
        case thread
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int.self, forKey: .seq)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        ephemeral = try container.decodeIfPresent(Bool.self, forKey: .ephemeral) ?? false
        event = try container.decode(SessionEvent.self, forKey: .event)
        thread = try container.decodeIfPresent(String.self, forKey: .thread)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(timestamp, forKey: .timestamp)
        if ephemeral { try container.encode(true, forKey: .ephemeral) }
        try container.encode(event, forKey: .event)
        try container.encodeIfPresent(thread, forKey: .thread)
    }
}
