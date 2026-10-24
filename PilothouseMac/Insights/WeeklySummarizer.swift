import Foundation
import FoundationModels
import PilothouseHost
import PilothouseKit

/// Writes the weekly narrative with Apple's on-device model (D-096). Nothing
/// leaves the Mac: the model runs locally through the Foundation Models framework.
struct AppleWeeklyNarrator: WeeklyNarrator {
    /// Projects summarised individually; the rest only appear in the numbers.
    static let maximumProjects = 8

    func unavailableReason() async -> String? {
        guard #available(macOS 26, *) else {
            return String(localized: "On-device summaries need macOS 26 or later on your Mac.")
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return String(localized: "This Mac does not support Apple Intelligence, so the summary shows numbers only.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return String(localized: "Turn on Apple Intelligence on your Mac (System Settings → Apple Intelligence & Siri) to get a written summary.")
        case .unavailable(.modelNotReady):
            return String(localized: "Apple Intelligence is still getting ready on your Mac. Try again later.")
        case .unavailable:
            return String(localized: "Apple Intelligence is not available on your Mac right now.")
        }
    }

    func narrate(_ summary: WeeklySummary, digests: [ProjectDigest]) async throws -> (WeeklyNarrative, [String: [String]]) {
        guard #available(macOS 26, *) else { throw NarratorError.unavailable }
        let language = Self.languageName()
        var bullets: [String: [String]] = [:]
        for digest in digests.prefix(Self.maximumProjects) {
            let session = LanguageModelSession(instructions: """
                You summarise a developer's week in one software project from a log of their chats with coding \
                agents. Write in \(language). Name concrete features, fixes and changes; no filler, no praise, \
                no numbers that are not in the log.
                """)
            let response = try await session.respond(to: digest.text, generating: ProjectBullets.self)
            bullets[digest.path] = Array(response.content.bullets.prefix(3))
        }

        let overview = summary.projects.prefix(Self.maximumProjects).map { project in
            let done = (bullets[project.path] ?? []).map { "  - \($0)" }.joined(separator: "\n")
            return "\(project.name): \(project.activeSeconds / 60) min, \(project.sessionCount) sessions\n\(done)"
        }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            You write the headline of a developer's weekly report from per-project notes. Write in \(language). \
            Be specific and brief; mention where most of the time went.
            """)
        let response = try await session.respond(to: overview, generating: WeekOverview.self)
        let narrative = WeeklyNarrative(headline: response.content.headline, highlights: Array(response.content.highlights.prefix(3)))
        return (narrative, bullets)
    }

    /// English name of the Mac's language, for the model's instructions.
    static func languageName() -> String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    enum NarratorError: Error {
        case unavailable
    }
}

@available(macOS 26, *)
@Generable
struct ProjectBullets {
    @Guide(description: "Two or three short bullet points: what was built, fixed or changed this week", .count(1...3))
    var bullets: [String]
}

@available(macOS 26, *)
@Generable
struct WeekOverview {
    @Guide(description: "One sentence that sums up the week")
    var headline: String
    @Guide(description: "Up to three short highlights across all projects", .count(1...3))
    var highlights: [String]
}
