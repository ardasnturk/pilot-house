import Foundation

/// A coding-agent CLI that Remote Code can drive on the Mac.
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
    /// The models the CLI itself offers, with names and effort levels
    /// (capability `modelCatalog`); `nil` when it could not be asked.
    public var modelOptions: [ModelOption]?

    public var id: AgentKind { kind }

    public init(
        kind: AgentKind, installed: Bool, path: String? = nil, version: String? = nil, loggedIn: Bool? = nil,
        models: [String] = [], delegationEnabled: Bool = false, modelOptions: [ModelOption]? = nil
    ) {
        self.kind = kind
        self.installed = installed
        self.path = path
        self.version = version
        self.loggedIn = loggedIn
        self.models = models
        self.delegationEnabled = delegationEnabled
        self.modelOptions = modelOptions
    }

    /// The default model (what an empty model selection runs).
    public var defaultModelOption: ModelOption? {
        modelOptions?.first(where: \.isDefault) ?? modelOptions?.first
    }

    /// The option for a model ID, alias or resolved name (`claude-opus-5-5`).
    public func modelOption(for model: String?) -> ModelOption? {
        guard let model, !model.isEmpty else { return defaultModelOption }
        return modelOptions?.first { $0.id == model } ?? modelOptions?.first { $0.resolvedModel == model }
    }

    /// Effort levels of a model, falling back to what the agent accepts in general.
    public func effortLevels(for model: String?) -> [String] {
        modelOption(for: model)?.effortLevels ?? (modelOptions == nil ? kind.effortLevels : [])
    }

    /// Installed and not known to be signed out.
    public var isUsable: Bool { installed && loggedIn != false }
}

/// One model an agent CLI offers (Claude Code's `initialize` response,
/// Codex's `model/list`).
public struct ModelOption: Sendable, Hashable, Codable, Identifiable {
    /// What is passed as `--model` / `model`, e.g. `opus` or `gpt-6-astra`.
    public var id: String
    /// Human name from the CLI, e.g. "Opus 5.5".
    public var displayName: String
    public var description: String?
    /// The full model name it resolves to, e.g. `claude-opus-5-5`.
    public var resolvedModel: String?
    /// Effort levels this model accepts, lowest first; empty = no effort setting.
    public var effortLevels: [String]
    /// The level used when none is chosen.
    public var defaultEffort: String?
    /// What the CLI runs when no model is chosen.
    public var isDefault: Bool

    public init(
        id: String, displayName: String, description: String? = nil, resolvedModel: String? = nil,
        effortLevels: [String] = [], defaultEffort: String? = nil, isDefault: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.resolvedModel = resolvedModel
        self.effortLevels = effortLevels
        self.defaultEffort = defaultEffort
        self.isDefault = isDefault
    }
}
