import Foundation
import RemoteCodeKit
import Testing
@testable import RemoteCodeHost

/// Reads the real Codex account limits (`account/rateLimits/read`, no model call).
///
///     REMOTECODE_E2E_CODEX=$(command -v codex) swift test --filter RealCodexLimitsTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["REMOTECODE_E2E_CODEX"] != nil))
struct RealCodexLimitsTests {
    @Test func readsLimitsWithoutATurn() async throws {
        let environment = ProcessInfo.processInfo.environment
        let codex = try #require(environment["REMOTECODE_E2E_CODEX"])
        let limits = try #require(await CodexLimitReader.read(executable: codex, environment: environment))
        #expect(limits.agent == .codex)
        #expect(limits.source == .live)
        #expect(!limits.windows.isEmpty)
        for window in limits.windows {
            print("codex \(window.id): \(window.usedPercent)% of \(window.durationMinutes ?? 0) min, resets \(window.resetsAt.map { "\($0)" } ?? "-")")
        }
    }
}
