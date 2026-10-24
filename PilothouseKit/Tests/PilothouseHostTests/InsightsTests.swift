import Foundation
import Synchronization
import PilothouseKit
import Testing
@testable import PilothouseHost

@Suite struct WeeklyStatsTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        calendar.firstWeekday = 2
        return calendar
    }()
    /// Monday 2026-10-19 09:00 in Istanbul.
    static let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9))!

    func session(_ id: String, cwd: String, title: String, agent: AgentKind? = nil) -> SessionSummary {
        SessionSummary(id: id, cwd: cwd, title: title, createdAt: Self.monday, updatedAt: Self.monday, agent: agent)
    }

    func event(_ minutes: Double, _ event: SessionEvent, thread: String? = nil, seq: Int = 1) -> SequencedEvent {
        SequencedEvent(seq: seq, timestamp: Self.monday.addingTimeInterval(minutes * 60), event: event, thread: thread)
    }

    @Test func activeTimeSkipsIdleGapsAndMergesParallelSessions() throws {
        let week = WeeklyStatsBuilder.week(containing: Self.monday, calendar: Self.calendar)
        let diff = "--- a/x\n+++ b/x\n@@ -1 +1,2 @@\n-a\n+b\n+c"
        let activity = [
            SessionActivity(summary: session("a", cwd: "/Users/demo/app", title: "Fix login"), events: [
                event(0, .userMessage(.init(text: "Fix the login"))),
                event(5, .fileEdit(.init(toolUseId: "t1", path: "/Users/demo/app/x.swift", kind: .modified, diff: diff))),
                event(6, .toolUse(.init(toolUseId: "t2", name: "Bash", input: ["command": "swift test"]))),
                event(10, .result(.init(isError: false, subtype: "success", durationMs: 1, usage: .init(inputTokens: 1, outputTokens: 500)))),
                // 2 h later: not counted as active time.
                event(130, .userMessage(.init(text: "Now the logout"))),
                event(140, .result(.init(isError: false, subtype: "success", durationMs: 1))),
            ]),
            // A parallel Codex session in the same folder overlapping the first one.
            SessionActivity(summary: session("b", cwd: "/Users/demo/app", title: "Review", agent: .codex), events: [
                event(4, .userMessage(.init(text: "Review"))),
                event(8, .assistantMessage(.init(blockId: "m", text: "Looks fine."))),
                event(9, .fileEdit(.init(toolUseId: "s1", path: "/Users/demo/app/y.swift", kind: .created, diff: "+z")), thread: "toolu_sub"),
                event(12, .result(.init(isError: false, subtype: "success", durationMs: 1))),
            ]),
            SessionActivity(summary: session("c", cwd: "/Users/demo/site", title: "Dark mode"), events: [
                event(60, .userMessage(.init(text: "Dark mode"))),
                event(63, .result(.init(isError: false, subtype: "success", durationMs: 1))),
                // Next week: ignored.
                event(8 * 24 * 60, .userMessage(.init(text: "Later"))),
            ]),
        ]
        let summary = WeeklyStatsBuilder.build(week: week, activity: activity, calendar: Self.calendar)
        #expect(summary.days.count == 7)
        #expect(summary.projects.map(\.name) == ["app", "site"])

        let app = summary.projects[0]
        // 0,4,5,6,8,9,10,12 → 12 min; then 130,140 → 10 min. Parallel sessions are not double counted.
        #expect(app.activeSeconds == 22 * 60)
        #expect(app.sessionCount == 2)
        #expect(app.turnCount == 3)
        #expect(app.agents == ["claude": 2, "codex": 1])
        #expect(app.filesChanged == 2)
        #expect(app.linesAdded == 3)
        #expect(app.linesRemoved == 1)
        #expect(app.commandsRun == 1)
        #expect(app.outputTokens == 500)
        #expect(app.sessionTitles == ["Fix login", "Review"])

        #expect(summary.projects[1].activeSeconds == 3 * 60)
        #expect(summary.days[0].activeSeconds == 25 * 60)
        #expect(summary.totalActiveSeconds == 25 * 60)

        let digests = WeeklyStatsBuilder.digest(of: summary, activity: activity)
        #expect(digests[0].text.contains("asked: Fix the login"))
        #expect(digests[0].text.contains("edited: x.swift"))
        #expect(!digests[1].text.contains("Later"))
    }

    @Test func firstSentenceIsShort() {
        #expect(WeeklyStatsBuilder.firstSentence("Done. Then more.", limit: 50) == "Done.")
        #expect(WeeklyStatsBuilder.firstSentence(String(repeating: "a", count: 30), limit: 10).count == 10)
    }
}

@Suite struct UsageLimitTests {
    /// Captured from Claude Code 2.1.310 (`claude -p --output-format stream-json`).
    static let claudeLine = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1792851000,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"org_level_disabled","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0,"resetsAt":1792851000},"seven_day":{"utilization":0.1,"resetsAt":1793386800}}},"uuid":"u","session_id":"s"}"#

    @Test func claudeWindowsFromRateLimitEvent() throws {
        let limits = try #require(UsageLimitParser.claude(try JSONValue.parse(Self.claudeLine)))
        #expect(limits.agent == .claude)
        #expect(limits.source == .lastTurn)
        #expect(limits.windows.map(\.key) == ["five_hour", "seven_day"])
        #expect(limits.windows.map(\.durationMinutes) == [300, 10_080])
        #expect(abs(limits.windows[1].usedPercent - 10) < 0.001)
        #expect(limits.windows[1].resetsAt == Date(timeIntervalSince1970: 1793386800))
        #expect(limits.windows.allSatisfy { !$0.isLimited })
    }

    @Test func claudeAdapterReportsLimits() {
        var adapter = ClaudeAdapter()
        let output = adapter.consume(line: Self.claudeLine)
        #expect(output.usageLimits?.windows.count == 2)
        #expect(output.events.isEmpty)
    }

    @Test func codexBucketsPerModel() throws {
        let result: JSONValue = try JSONValue.parse(#"""
        {"ordinaryUsageAllowed":true,
         "rateLimits":{"limitId":"codex","primary":{"usedPercent":22,"windowDurationMins":10080,"resetsAt":1793435087},"secondary":null,"planType":"pro"},
         "rateLimitsByLimitId":{
           "codex":{"limitId":"codex","normalModelSlug":"gpt-6.1-sol","primary":{"usedPercent":22,"windowDurationMins":10080,"resetsAt":1793435087},"secondary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":1792850000},"planType":"pro"},
           "codex_astra":{"limitId":"codex_astra","normalModelSlug":"gpt-6.1-astra","primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1793435087},"secondary":null,"planType":"pro","rateLimitReachedType":"primary"}
         }}
        """#)
        let limits = try #require(UsageLimitParser.codex(result))
        #expect(limits.plan == "pro")
        #expect(limits.windows.count == 3)
        #expect(limits.windows.map(\.model) == ["gpt-6.1-sol", "gpt-6.1-sol", "gpt-6.1-astra"])
        #expect(limits.windows[2].isLimited)
        #expect(limits.windows[0].durationMinutes == 10_080)

        let single = try #require(UsageLimitParser.codex(["rateLimits": result["rateLimits"] ?? nil]))
        #expect(single.windows.count == 1)
        #expect(single.windows[0].model == nil)
    }

    @Test func storePersistsAndFillsUnknownAgents() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let url = home.url.appendingPathComponent("usage-limits.json")
        let store = UsageLimitStore(url: url)
        await store.update(try #require(UsageLimitParser.claude(try JSONValue.parse(Self.claudeLine))))
        let reloaded = UsageLimitStore(url: url)
        let all = await reloaded.all(for: [.claude, .codex, .gemini])
        #expect(all.map(\.windows.count) == [2, 0, 0])
        #expect(all[2].source == .unavailable)
    }
}

@Suite(.serialized) struct InsightsServiceTests {
    final class FakeNarrator: WeeklyNarrator {
        let reason: String?
        let calls = Mutex(0)
        init(reason: String?) { self.reason = reason }
        func unavailableReason() async -> String? { reason }
        func narrate(_ summary: WeeklySummary, digests: [ProjectDigest]) async throws -> (WeeklyNarrative, [String: [String]]) {
            calls.withLock { $0 += 1 }
            return (WeeklyNarrative(headline: "Busy week", highlights: ["Did things"]), [digests[0].path: ["Wrote code"]])
        }
    }

    @Test func narratesCachesAndExplainsUnavailability() async throws {
        let harness = try await SessionManagerTests.Harness()
        defer { Task { await harness.tearDown() } }
        let session = try await harness.sessions.start(StartSession(cwd: "~/project", firstMessage: "hello"))
        _ = try await collect(try await harness.sessions.subscribe(session.id, fromSeq: 1)) { $0.resultCount >= 1 }

        let insights = harness.runtime.insights
        let narrator = FakeNarrator(reason: nil)
        await insights.configure(narrator: narrator, agents: [.claude], liveReaders: [:])
        let first = await insights.weeklySummary(GetWeeklySummary())
        #expect(first.projects.map(\.name) == ["project"])
        #expect(first.narrative?.headline == "Busy week")
        #expect(first.projects[0].highlights == ["Wrote code"])

        _ = await insights.weeklySummary(GetWeeklySummary())
        #expect(narrator.calls.withLock { $0 } == 1, "The current week is cached for an hour")
        _ = await insights.weeklySummary(GetWeeklySummary(refresh: true))
        #expect(narrator.calls.withLock { $0 } == 2)

        await insights.configure(narrator: FakeNarrator(reason: "Apple Intelligence is off."), agents: [.claude], liveReaders: [:])
        let fallback = await insights.weeklySummary(GetWeeklySummary(refresh: true))
        #expect(fallback.narrative == nil)
        #expect(fallback.narrativeUnavailableReason == "Apple Intelligence is off.")
        #expect(fallback.projects.count == 1)

        let empty = await insights.weeklySummary(GetWeeklySummary(week: Date(timeIntervalSince1970: 0)))
        #expect(empty.projects.isEmpty)
        #expect(empty.narrativeUnavailableReason == nil)
    }

    @Test func liveReadersRefreshLimits() async throws {
        let harness = try await SessionManagerTests.Harness()
        defer { Task { await harness.tearDown() } }
        let insights = harness.runtime.insights
        let reads = Mutex(0)
        await insights.configure(narrator: nil, agents: [.claude, .codex], liveReaders: [
            .codex: {
                reads.withLock { $0 += 1 }
                return UsageLimits(agent: .codex, windows: [LimitWindow(key: "primary", durationMinutes: 10_080, usedPercent: 40, resetsAt: nil)], observedAt: Date(), source: .live)
            },
        ])
        let limits = await insights.usageLimits()
        #expect(limits.map(\.agent) == [.claude, .codex])
        #expect(limits[1].windows.first?.usedPercent == 40)
        _ = await insights.usageLimits()
        #expect(reads.withLock { $0 } == 1, "Live reads are cached for a minute")
    }
}
