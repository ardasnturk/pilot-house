import Foundation

/// What happened on the Mac in one week (capability `insights`).
public struct WeeklySummary: Sendable, Hashable, Codable {
    /// Start of the week (local midnight of its first day) and its end (exclusive).
    public var weekStart: Date
    public var weekEnd: Date
    public var projects: [ProjectActivity]
    /// One entry per day of the week, in order.
    public var days: [DayActivity]
    /// Written by the Mac's on-device model; `nil` when it is unavailable.
    public var narrative: WeeklyNarrative?
    /// Why there is no narrative (shown to the user), if so.
    public var narrativeUnavailableReason: String?
    public var generatedAt: Date

    public init(
        weekStart: Date, weekEnd: Date, projects: [ProjectActivity], days: [DayActivity],
        narrative: WeeklyNarrative? = nil, narrativeUnavailableReason: String? = nil, generatedAt: Date = Date()
    ) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.projects = projects
        self.days = days
        self.narrative = narrative
        self.narrativeUnavailableReason = narrativeUnavailableReason
        self.generatedAt = generatedAt
    }

    public var totalActiveSeconds: Int { projects.reduce(0) { $0 + $1.activeSeconds } }
    public var sessionCount: Int { projects.reduce(0) { $0 + $1.sessionCount } }
}

/// Activity in one project folder during the week.
public struct ProjectActivity: Sendable, Hashable, Codable, Identifiable {
    /// Absolute folder path on the Mac.
    public var path: String
    public var name: String
    /// Time with gaps under 15 minutes between events, in seconds.
    public var activeSeconds: Int
    public var sessionCount: Int
    public var turnCount: Int
    /// Turns per agent (`claude`, `codex`, …).
    public var agents: [String: Int]
    public var filesChanged: Int
    public var linesAdded: Int
    public var linesRemoved: Int
    public var commandsRun: Int
    public var outputTokens: Int
    /// Session titles, newest first (what was worked on).
    public var sessionTitles: [String]
    /// Bullet points from the on-device model, if any.
    public var highlights: [String]

    public var id: String { path }

    public init(
        path: String, name: String, activeSeconds: Int = 0, sessionCount: Int = 0, turnCount: Int = 0,
        agents: [String: Int] = [:], filesChanged: Int = 0, linesAdded: Int = 0, linesRemoved: Int = 0,
        commandsRun: Int = 0, outputTokens: Int = 0, sessionTitles: [String] = [], highlights: [String] = []
    ) {
        self.path = path
        self.name = name
        self.activeSeconds = activeSeconds
        self.sessionCount = sessionCount
        self.turnCount = turnCount
        self.agents = agents
        self.filesChanged = filesChanged
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.commandsRun = commandsRun
        self.outputTokens = outputTokens
        self.sessionTitles = sessionTitles
        self.highlights = highlights
    }
}

public struct DayActivity: Sendable, Hashable, Codable, Identifiable {
    public var day: Date
    public var activeSeconds: Int
    public var id: Date { day }

    public init(day: Date, activeSeconds: Int) {
        self.day = day
        self.activeSeconds = activeSeconds
    }
}

/// The model-written part of a weekly summary.
public struct WeeklyNarrative: Sendable, Hashable, Codable {
    public var headline: String
    public var highlights: [String]

    public init(headline: String, highlights: [String]) {
        self.headline = headline
        self.highlights = highlights
    }
}

/// Usage limits of one agent, as last reported by its CLI.
public struct UsageLimits: Sendable, Hashable, Codable, Identifiable {
    public enum Source: String, Sendable, Hashable, Codable {
        /// Read on request without a model call (Codex `account/rateLimits/read`).
        case live
        /// Reported during the last turn (Claude `rate_limit_event`).
        case lastTurn
        /// The CLI does not report limits.
        case unavailable
    }

    public var agent: AgentKind
    public var windows: [LimitWindow]
    public var observedAt: Date?
    public var source: Source
    /// Plan name if the CLI reports one (e.g. `pro`).
    public var plan: String?

    public var id: AgentKind { agent }

    public init(agent: AgentKind, windows: [LimitWindow], observedAt: Date?, source: Source, plan: String? = nil) {
        self.agent = agent
        self.windows = windows
        self.observedAt = observedAt
        self.source = source
        self.plan = plan
    }
}

/// One rolling usage window, e.g. Claude's five-hour or Codex's weekly limit.
public struct LimitWindow: Sendable, Hashable, Codable, Identifiable {
    /// Stable key: `five_hour`, `seven_day`, `primary`, `secondary`, …
    public var key: String
    /// Window length in minutes, if known (300, 10_080, …).
    public var durationMinutes: Int?
    /// 0…100.
    public var usedPercent: Double
    public var resetsAt: Date?
    /// The model this bucket applies to, when limits are per model.
    public var model: String?
    /// The limit is exhausted right now.
    public var isLimited: Bool

    public var id: String { [key, model].compactMap { $0 }.joined(separator: ":") }

    public init(key: String, durationMinutes: Int?, usedPercent: Double, resetsAt: Date?, model: String? = nil, isLimited: Bool = false) {
        self.key = key
        self.durationMinutes = durationMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.model = model
        self.isLimited = isLimited
    }
}

public struct GetWeeklySummary: Sendable, Hashable, Codable {
    /// Any moment inside the wanted week; `nil` = this week.
    public var week: Date?
    /// Rebuild even if a cached summary exists.
    public var refresh: Bool

    public init(week: Date? = nil, refresh: Bool = false) {
        self.week = week
        self.refresh = refresh
    }
}

public struct UsageLimitsPayload: Sendable, Hashable, Codable {
    public var agents: [UsageLimits]
    public init(agents: [UsageLimits]) { self.agents = agents }
}
