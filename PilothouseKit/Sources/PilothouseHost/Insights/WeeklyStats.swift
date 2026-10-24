import Foundation
import PilothouseKit

/// One session's events in the week being summarised.
public struct SessionActivity: Sendable {
    public var summary: SessionSummary
    public var events: [SequencedEvent]

    public init(summary: SessionSummary, events: [SequencedEvent]) {
        self.summary = summary
        self.events = events
    }
}

/// Turns session logs into the numbers of a `WeeklySummary` (D-096).
///
/// Active time is the sum of gaps shorter than `idleGap` between consecutive
/// events of a project, across all its sessions and sub-agents, so a project
/// worked on in two parallel sessions is not counted twice.
public enum WeeklyStatsBuilder {
    public static let idleGap: TimeInterval = 15 * 60

    /// The calendar week containing `date` (locale's first weekday).
    public static func week(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 86_400)
    }

    public static func build(
        week: DateInterval, activity: [SessionActivity], calendar: Calendar = .current, now: Date = Date()
    ) -> WeeklySummary {
        let inWeek = activity.compactMap { item -> SessionActivity? in
            let events = item.events.filter { !$0.ephemeral && week.contains($0.timestamp) }
            return events.isEmpty ? nil : SessionActivity(summary: item.summary, events: events)
        }
        var dayTotals: [Date: Int] = [:]
        var projects: [ProjectActivity] = []
        for (path, sessions) in Dictionary(grouping: inWeek, by: \.summary.cwd) {
            var project = ProjectActivity(path: path, name: sessions[0].summary.folderName)
            project.sessionCount = sessions.count
            var timestamps: [Date] = []
            var files = Set<String>()
            for session in sessions {
                for event in session.events {
                    timestamps.append(event.timestamp)
                    switch event.event {
                    case .result(let result) where event.thread == nil:
                        project.turnCount += 1
                        project.agents[session.summary.agentKind.rawValue, default: 0] += 1
                        project.outputTokens += result.usage?.outputTokens ?? 0
                    case .fileEdit(let edit):
                        files.insert(edit.path)
                        let stats = DiffBuilder.stats(of: edit.diff)
                        project.linesAdded += stats.added
                        project.linesRemoved += stats.removed
                    case .toolUse(let use) where use.name == "Bash":
                        project.commandsRun += 1
                    default:
                        break
                    }
                }
            }
            project.filesChanged = files.count
            timestamps.sort()
            for (previous, next) in zip(timestamps, timestamps.dropFirst()) {
                let gap = next.timeIntervalSince(previous)
                guard gap > 0, gap < idleGap else { continue }
                project.activeSeconds += Int(gap)
                dayTotals[calendar.startOfDay(for: next), default: 0] += Int(gap)
            }
            project.sessionTitles = sessions
                .sorted { ($0.events.last?.timestamp ?? .distantPast) > ($1.events.last?.timestamp ?? .distantPast) }
                .map(\.summary.title)
            projects.append(project)
        }
        projects.sort { $0.activeSeconds == $1.activeSeconds ? $0.name < $1.name : $0.activeSeconds > $1.activeSeconds }

        var days: [DayActivity] = []
        var day = calendar.startOfDay(for: week.start)
        while day < week.end {
            days.append(DayActivity(day: day, activeSeconds: dayTotals[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return WeeklySummary(weekStart: week.start, weekEnd: week.end, projects: projects, days: days, generatedAt: now)
    }

    /// Compact text the on-device model summarises: per project its numbers,
    /// session titles, what the user asked and how the agent answered.
    public static func digest(
        of summary: WeeklySummary, activity: [SessionActivity], maximumCharacters: Int = 12_000
    ) -> [ProjectDigest] {
        let perProject = max(600, maximumCharacters / max(1, summary.projects.count))
        return summary.projects.map { project in
            var lines = [
                "Project: \(project.name)",
                "Active: \(project.activeSeconds / 60) min, \(project.sessionCount) sessions, \(project.turnCount) turns, "
                    + "\(project.filesChanged) files changed (+\(project.linesAdded) −\(project.linesRemoved))",
            ]
            for item in activity where item.summary.cwd == project.path {
                let main = item.events.filter { $0.thread == nil && summaryWeek(summary).contains($0.timestamp) }
                guard !main.isEmpty else { continue }
                lines.append("Session: \(item.summary.title)")
                for event in main {
                    switch event.event {
                    case .userMessage(let message) where !message.text.isEmpty:
                        lines.append("- asked: \(firstSentence(message.text, limit: 160))")
                    case .assistantMessage(let message):
                        lines.append("- answered: \(firstSentence(message.text, limit: 160))")
                    case .fileEdit(let edit):
                        lines.append("- edited: \((edit.path as NSString).lastPathComponent)")
                    default:
                        continue
                    }
                }
            }
            var text = ""
            for line in lines where text.count + line.count + 1 <= perProject {
                text += line + "\n"
            }
            return ProjectDigest(path: project.path, name: project.name, text: text)
        }
    }

    private static func summaryWeek(_ summary: WeeklySummary) -> DateInterval {
        DateInterval(start: summary.weekStart, end: summary.weekEnd)
    }

    static func firstSentence(_ text: String, limit: Int) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let end = flattened.firstIndex { ".!?".contains($0) }.map { flattened.index(after: $0) } ?? flattened.endIndex
        let sentence = String(flattened[..<end])
        return sentence.count > limit ? String(sentence.prefix(limit - 1)) + "…" : sentence
    }
}

/// What the model reads about one project.
public struct ProjectDigest: Sendable, Hashable {
    public var path: String
    public var name: String
    public var text: String
}

/// Writes the narrative of a weekly summary; implemented by the Mac app with
/// Apple's on-device model so the package stays platform-neutral.
public protocol WeeklyNarrator: Sendable {
    /// `nil` when the narrator can run, otherwise why not (shown to the user).
    func unavailableReason() async -> String?
    /// Headline and highlights for the week, plus per-project bullet points by path.
    func narrate(_ summary: WeeklySummary, digests: [ProjectDigest]) async throws -> (WeeklyNarrative, [String: [String]])
}
