import Foundation
import PilothouseKit

/// Weekly summaries and usage limits for the phone (capability `insights`).
///
/// Summaries are cached per week in `insights/<week-start>.json`: past weeks
/// are built once, the current week at most once an hour unless refreshed.
public actor InsightsService {
    public static let currentWeekMaxAge: TimeInterval = 60 * 60
    public static let liveLimitMaxAge: TimeInterval = 60

    public nonisolated let limits: UsageLimitStore
    private let sessions: SessionManager
    private let directory: URL
    private let calendar: Calendar
    private var narrator: (any WeeklyNarrator)?
    private var liveReaders: [AgentKind: @Sendable () async -> UsageLimits?] = [:]
    private var agents: [AgentKind] = [.claude]
    private var building: [Date: Task<WeeklySummary, Never>] = [:]

    public init(sessions: SessionManager, dataDirectory: URL, calendar: Calendar = .current) {
        self.sessions = sessions
        directory = dataDirectory.appendingPathComponent("insights", isDirectory: true)
        limits = UsageLimitStore(url: dataDirectory.appendingPathComponent("usage-limits.json"))
        self.calendar = calendar
    }

    /// Set by the Mac app: the on-device narrator, installed agents and how to
    /// read live limits (Codex) without a model call.
    public func configure(
        narrator: (any WeeklyNarrator)?, agents: [AgentKind],
        liveReaders: [AgentKind: @Sendable () async -> UsageLimits?]
    ) {
        self.narrator = narrator
        self.agents = agents.isEmpty ? [.claude] : agents
        self.liveReaders = liveReaders
    }

    // MARK: Weekly summary

    public func weeklySummary(_ request: GetWeeklySummary, now: Date = Date()) async -> WeeklySummary {
        let week = WeeklyStatsBuilder.week(containing: request.week ?? now, calendar: calendar)
        if !request.refresh, let cached = cached(week), isFresh(cached, now: now) {
            return cached
        }
        if let running = building[week.start] {
            return await running.value
        }
        let task = Task { await self.build(week, now: now) }
        building[week.start] = task
        let summary = await task.value
        building.removeValue(forKey: week.start)
        store(summary)
        return summary
    }

    private func isFresh(_ summary: WeeklySummary, now: Date) -> Bool {
        if summary.weekEnd <= summary.generatedAt { return true }  // built after the week ended
        return now.timeIntervalSince(summary.generatedAt) < Self.currentWeekMaxAge
    }

    private func build(_ week: DateInterval, now: Date) async -> WeeklySummary {
        let activity = await sessions.activity(in: week)
        var summary = WeeklyStatsBuilder.build(week: week, activity: activity, calendar: calendar, now: now)
        guard !summary.projects.isEmpty else { return summary }
        guard let narrator else {
            summary.narrativeUnavailableReason = "On-device summaries need Apple Intelligence on the Mac (macOS 26 or later)."
            return summary
        }
        if let reason = await narrator.unavailableReason() {
            summary.narrativeUnavailableReason = reason
            return summary
        }
        do {
            let digests = WeeklyStatsBuilder.digest(of: summary, activity: activity)
            let (narrative, highlights) = try await narrator.narrate(summary, digests: digests)
            summary.narrative = narrative
            for index in summary.projects.indices {
                summary.projects[index].highlights = highlights[summary.projects[index].path] ?? []
            }
        } catch {
            summary.narrativeUnavailableReason = "The on-device model could not write a summary: \(error.localizedDescription)"
        }
        return summary
    }

    private func url(for week: DateInterval) -> URL {
        let day = calendar.dateComponents([.year, .month, .day], from: week.start)
        let name = String(format: "%04d-%02d-%02d.json", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return directory.appendingPathComponent(name)
    }

    private func cached(_ week: DateInterval) -> WeeklySummary? {
        guard let data = try? Data(contentsOf: url(for: week)) else { return nil }
        return try? PilothouseJSON.decode(WeeklySummary.self, from: data)
    }

    private func store(_ summary: WeeklySummary) {
        let week = DateInterval(start: summary.weekStart, end: summary.weekEnd)
        if let data = try? PilothouseJSON.encode(summary) {
            try? PrivateFiles.writeAtomically(data, to: url(for: week))
        }
    }

    // MARK: Limits

    /// Fresh live limits where an agent offers them, the last reported ones otherwise.
    public func usageLimits(now: Date = Date()) async -> [UsageLimits] {
        await withTaskGroup(of: Void.self) { group in
            for (agent, read) in liveReaders where agents.contains(agent) {
                let known = await limits.limits(for: agent)
                if let observed = known?.observedAt, known?.source == .live, now.timeIntervalSince(observed) < Self.liveLimitMaxAge {
                    continue
                }
                let store = limits
                group.addTask {
                    if let value = await read() { await store.update(value) }
                }
            }
        }
        return await limits.all(for: agents)
    }
}
