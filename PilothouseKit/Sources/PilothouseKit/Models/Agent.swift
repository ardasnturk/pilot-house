import Foundation

/// A coding-agent CLI that Pilothouse can drive on the Mac.
///
/// Open-ended like `ErrorCode`, so a newer Mac can offer agents an older
/// phone does not know yet; the phone shows them by `displayName`.
public struct AgentKind: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Claude Code (`claude`), the default and the only agent before 1.1.
    public static let claude = AgentKind("claude")
    /// OpenAI Codex CLI (`codex app-server`).
    public static let codex = AgentKind("codex")
    /// Google Gemini CLI (`gemini --experimental-acp`).
    public static let gemini = AgentKind("gemini")

    /// Agents this build knows how to drive, in the order they are offered.
    public static let known: [AgentKind] = [.claude, .codex, .gemini]

    /// Name of the executable looked up on the Mac.
    public var executableName: String { rawValue }

    /// Effort (reasoning) levels the agent's CLI accepts, lowest first; empty
    /// when it has no such setting. Claude Code: `--effort`; Codex: `turn/start.effort`.
    public var effortLevels: [String] {
        switch self {
        case .claude: ["low", "medium", "high", "xhigh", "max"]
        case .codex: ["low", "medium", "high", "xhigh"]
        default: []
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        default: rawValue.capitalized
        }
    }
}

/// What the Mac knows about one agent CLI (part of `MacStatus.agents`).
public struct AgentStatus: Sendable, Hashable, Codable, Identifiable {
    public var kind: AgentKind
    public var installed: Bool
    public var path: String?
    public var version: String?
    /// `nil` when the CLI cannot tell without starting a session.
    public var loggedIn: Bool?
    /// Model IDs to offer; empty means "the agent's default" only.
    public var models: [String]
    /// The Mac can start this agent as a sub-agent for another session.
    public var delegationEnabled: Bool

    public var id: AgentKind { kind }

    public init(
        kind: AgentKind, installed: Bool, path: String? = nil, version: String? = nil, loggedIn: Bool? = nil,
        models: [String] = [], delegationEnabled: Bool = false
    ) {
        self.kind = kind
        self.installed = installed
        self.path = path
        self.version = version
        self.loggedIn = loggedIn
        self.models = models
        self.delegationEnabled = delegationEnabled
    }

    /// Installed and not known to be signed out.
    public var isUsable: Bool { installed && loggedIn != false }
}
