import Foundation
import PilothouseKit
import Testing
@testable import PilothouseHost

/// Builds this week's stats from a *copy* of a real Pilothouse data folder and
/// writes the model digest next to it, for checking the summary by hand.
///
///     PILOTHOUSE_REAL_DATA=/path/to/copy swift test --filter RealWeeklyStatsTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PILOTHOUSE_REAL_DATA"] != nil))
struct RealWeeklyStatsTests {
    @Test func buildsThisWeekFromRealLogs() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PILOTHOUSE_REAL_DATA"]))
        let manager = SessionManager(
            configuration: HostConfiguration(dataDirectory: folder),
            broker: PermissionBroker(hub: NotificationHub()), hub: NotificationHub(),
            launcher: { throw ErrorPayload(code: .claudeNotInstalled, message: "read only") }
        )
        await manager.bootstrap()
        let week = WeeklyStatsBuilder.week(containing: Date())
        let activity = await manager.activity(in: week)
        let summary = WeeklyStatsBuilder.build(week: week, activity: activity)
        for project in summary.projects {
            print("project \(project.name): \(project.activeSeconds / 60) min, \(project.sessionCount) sessions, \(project.turnCount) turns, \(project.filesChanged) files +\(project.linesAdded) −\(project.linesRemoved), agents \(project.agents)")
        }
        let digest = WeeklyStatsBuilder.digest(of: summary, activity: activity).map(\.text).joined(separator: "\n---\n")
        try digest.write(to: folder.appendingPathComponent("digest.txt"), atomically: true, encoding: .utf8)
        print("total \(summary.totalActiveSeconds / 60) min in \(summary.projects.count) projects")
    }
}
