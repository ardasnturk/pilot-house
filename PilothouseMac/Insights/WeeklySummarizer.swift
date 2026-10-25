import Foundation
import FoundationModels
import PilothouseHost
import PilothouseKit

/// Writes the weekly narrative with Apple's on-device model (D-096). Nothing
/// leaves the Mac: the model runs locally through the Foundation Models framework.
struct AppleWeeklyNarrator: WeeklyNarrator {
    /// Projects summarised individually; the rest only appear in the numbers.
    static let maximumProjects = 8

    func unavailableReason(language: String?) async -> String? {
        let bundle = Self.bundle(for: language)
        guard #available(macOS 26, *) else {
            return String(localized: "On-device summaries need macOS 26 or later on your Mac.", bundle: bundle)
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return String(localized: "This Mac does not support Apple Intelligence, so the summary shows numbers only.", bundle: bundle)
        case .unavailable(.appleIntelligenceNotEnabled):
            return String(localized: "Turn on Apple Intelligence on your Mac (System Settings → Apple Intelligence & Siri) to get a written summary.", bundle: bundle)
        case .unavailable(.modelNotReady):
            return String(localized: "Apple Intelligence is still getting ready on your Mac. Try again later.", bundle: bundle)
        case .unavailable:
            return String(localized: "Apple Intelligence is not available on your Mac right now.", bundle: bundle)
        }
    }

    func narrate(
        _ summary: WeeklySummary, digests: [ProjectDigest], language: String?
    ) async throws -> (WeeklyNarrative, [String: [String]]) {
        guard #available(macOS 26, *) else { throw NarratorError.unavailable }
        let language = Self.languageName(language)
        var bullets: [String: [String]] = [:]
        for digest in digests.prefix(Self.maximumProjects) {
            let session = LanguageModelSession(instructions: """
                You summarise a developer's week in one software project from a log of their chats with coding \
                agents. Write in \(language), even where the log is in another language. Name concrete features, \
                fixes and changes; no filler, no praise, no numbers that are not in the log.
                """)
            let response = try await session.respond(to: digest.text, generating: ProjectBullets.self)
            bullets[digest.path] = Array(response.content.bullets.prefix(3))
        }

        let overview = summary.projects.prefix(Self.maximumProjects).map { project in
            let done = (bullets[project.path] ?? []).map { "  - \($0)" }.joined(separator: "\n")
            return "\(project.name): \(project.activeSeconds / 60) min, \(project.sessionCount) sessions\n\(done)"
        }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            You write the headline of a developer's weekly report from per-project notes. Write in \(language), \
            even where the notes are in another language. Be specific and brief; mention where most of the time went.
            """)
        let response = try await session.respond(to: overview, generating: WeekOverview.self)
        let narrative = WeeklyNarrative(headline: response.content.headline, highlights: Array(response.content.highlights.prefix(3)))
        return (narrative, bullets)
    }

    /// English name of the phone's language (BCP 47) or else the Mac's, for
    /// the model's instructions.
    static func languageName(_ language: String?) -> String {
        let identifier = language ?? Locale.current.language.minimalIdentifier
        return Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? "English"
    }

    /// The app's strings in the phone's language (BCP 47), so reasons shown on
    /// the phone match it; the Mac's language when `nil` or not translated.
    static func bundle(for language: String?) -> Bundle {
        guard
            let language,
            let match = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: [language]).first,
            let path = Bundle.main.path(forResource: match, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else { return .main }
        return bundle
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
