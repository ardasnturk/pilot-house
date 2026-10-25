import Foundation

/// Claude Code permission modes exposed by Remote Code (docs/DECISIONS.md D-006).
public enum PermissionMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Ask before edits and commands (shown as "Manual" by the CLI).
    case `default`
    /// Auto-approve file edits, ask for everything else.
    case acceptEdits
    /// Read-only planning.
    case plan
    /// Never ask. Only available after explicit opt-in in the Mac settings.
    case bypassPermissions

    /// Modes that are always offered; `bypassPermissions` requires opt-in.
    public static let standardModes: [PermissionMode] = [.default, .acceptEdits, .plan]

    /// Lenient decoding: the CLI alias `manual` and unknown future modes map to `.default`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PermissionMode(rawValue: raw) ?? .default
    }
}

/// Lifecycle state of a session as seen by clients.
public enum SessionState: String, Sendable, Hashable, Codable {
    /// The CLI is starting up.
    case starting
    /// A turn is in progress.
    case running
    /// A turn is waiting for a permission decision.
    case awaitingPermission
    /// Ready for the next message (the CLI may or may not be running).
    case idle
    /// Closed by the user; can be continued with `resumeSession`.
    case closed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionState(rawValue: raw) ?? .idle
    }

    /// `true` while Claude is working on something.
    public var isBusy: Bool {
        self == .starting || self == .running || self == .awaitingPermission
    }
}

/// What a client needs to list and open a session.
public struct SessionSummary: Sendable, Hashable, Codable, Identifiable {
    /// Remote Code session ID. Equal to the Claude session ID (passed with
    /// `--session-id`), so it is also what `--resume` takes.
    public var id: String
    /// Absolute working directory on the Mac.
    public var cwd: String
    public var title: String
    public var lastMessagePreview: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var model: String?
    public var permissionMode: PermissionMode
    public var state: SessionState
    /// Sequence number of the newest persisted event.
    public var lastSeq: Int
    /// Slash commands reported by the CLI for this session (without the leading `/`).
    public var slashCommands: [String]
    /// The agent CLI running this session; `nil` (older Macs) means Claude Code.
    public var agent: AgentKind?
    /// Effort level chosen for this session (`AgentKind.effortLevels`); `nil` = the agent's default.
    public var effort: String?

    public init(
        id: String, cwd: String, title: String, lastMessagePreview: String? = nil, createdAt: Date, updatedAt: Date,
        model: String? = nil, permissionMode: PermissionMode = .default, state: SessionState = .idle, lastSeq: Int = 0,
        slashCommands: [String] = [], agent: AgentKind? = nil, effort: String? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.lastMessagePreview = lastMessagePreview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.permissionMode = permissionMode
        self.state = state
        self.lastSeq = lastSeq
        self.slashCommands = slashCommands
        self.agent = agent
        self.effort = effort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cwd = try container.decode(String.self, forKey: .cwd)
        title = try container.decode(String.self, forKey: .title)
        lastMessagePreview = try container.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        permissionMode = try container.decodeIfPresent(PermissionMode.self, forKey: .permissionMode) ?? .default
        state = try container.decodeIfPresent(SessionState.self, forKey: .state) ?? .idle
        lastSeq = try container.decodeIfPresent(Int.self, forKey: .lastSeq) ?? 0
        slashCommands = try container.decodeIfPresent([String].self, forKey: .slashCommands) ?? []
        agent = try container.decodeIfPresent(AgentKind.self, forKey: .agent)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
    }

    /// The agent running this session (Claude Code when the Mac did not say).
    public var agentKind: AgentKind { agent ?? .claude }

    /// Last path component of `cwd`, or `~` for the home folder.
    public var folderName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "~" : name
    }
}

/// A permission prompt forwarded from Claude to the phone.
public struct PermissionRequest: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var sessionId: String
    /// Tool name as Claude reports it (`Bash`, `Edit`, `Write`, `mcp__x__y`, …).
    public var tool: String
    public var input: JSONValue
    public var cwd: String
    public var createdAt: Date
    /// After this instant the Mac denies the request automatically.
    public var expiresAt: Date
    /// What "always allow in this session" would remember, e.g. `Bash(npm)`.
    public var rememberKey: String

    private enum CodingKeys: String, CodingKey {
        case id = "requestId"
        case sessionId, tool, input, cwd, createdAt, expiresAt, rememberKey
    }

    public init(
        id: String, sessionId: String, tool: String, input: JSONValue, cwd: String, createdAt: Date, expiresAt: Date,
        rememberKey: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.tool = tool
        self.input = input
        self.cwd = cwd
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.rememberKey = rememberKey
    }

    /// The key under which an "always allow" decision is remembered for a session.
    /// Bash is remembered per program (first word of the command); every other
    /// tool by name.
    public static func rememberKey(tool: String, input: JSONValue) -> String {
        guard tool == "Bash", let command = input["command"]?.stringValue else { return tool }
        let program = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .first
            .map(String.init) ?? ""
        return program.isEmpty ? tool : "Bash(\(program))"
    }

    /// One-line human summary used in transcripts and notifications.
    public var summary: String {
        PermissionRequest.summary(tool: tool, input: input)
    }

    public static func summary(tool: String, input: JSONValue) -> String {
        switch tool {
        case "Bash":
            return input["command"]?.stringValue ?? tool
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            return input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue ?? tool
        case "WebFetch":
            return input["url"]?.stringValue ?? tool
        case "WebSearch":
            return input["query"]?.stringValue ?? tool
        default:
            return tool
        }
    }
}
