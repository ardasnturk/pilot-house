import AppKit
import Foundation
import Observation

/// Talks to the GitHub Releases API.
enum UpdateChecker {
    static let repository = "ardasnturk/pilot-house"
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let releasesPageURL = URL(string: "https://github.com/\(repository)/releases/latest")!

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "Pilothouse-Mac/\(version) (+https://github.com/\(repository))"
    }

    enum Failure: Error {
        case network
        case noRelease
        case rateLimited
        case httpStatus(Int)
        case unusable(ReleaseParseError)
    }

    /// The latest stable release, or `nil` when the repository has none yet.
    static func latestRelease() async throws -> Release? {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 404: return nil // no published (non-draft, non-prerelease) release
        case 403, 429: throw Failure.rateLimited
        default: throw Failure.httpStatus(status)
        }
        do {
            return try ReleaseParser.parse(data)
        } catch ReleaseParseError.draftOrPrerelease {
            return nil
        } catch let error as ReleaseParseError {
            throw Failure.unusable(error)
        }
    }
}

/// Finds and installs newer Pilothouse releases from GitHub (no Sparkle).
///
/// Wiring: create once (next to `AppSettings`), call `startAutomaticChecks()`
/// once after launch, and show `state` / `releaseNotes` in the UI.
@MainActor
@Observable
final class AppUpdater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(progress: Double)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The newest release found by the last successful check that is newer than this app.
    private(set) var availableRelease: Release?
    /// When the last check finished successfully.
    private(set) var lastCheckDate: Date?

    /// Markdown release notes (`body`) of the available release; empty when none.
    var releaseNotes: String { availableRelease?.notes ?? "" }

    /// CFBundleShortVersionString of the running app.
    let currentVersion: String

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var automaticTask: Task<Void, Never>?

    static let initialCheckDelay: Duration = .seconds(30)
    static let checkInterval: TimeInterval = 24 * 60 * 60

    init(settings: AppSettings, bundle: Bundle = .main) {
        self.settings = settings
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    // MARK: Automatic checks

    /// Checks ~30 s after launch, then every 24 h while
    /// `AppSettings.automaticallyChecksForUpdates` is on. Idempotent.
    func startAutomaticChecks() {
        guard automaticTask == nil else { return }
        automaticTask = Task { [weak self] in
            try? await Task.sleep(for: Self.initialCheckDelay)
            while !Task.isCancelled {
                guard let self else { return }
                if self.settings.automaticallyChecksForUpdates, self.isAutomaticCheckDue {
                    await self.checkForUpdates(userInitiated: false)
                }
                // Re-evaluate hourly so toggling the setting or waking from sleep is picked up.
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    func stopAutomaticChecks() {
        automaticTask?.cancel()
        automaticTask = nil
    }

    private var isAutomaticCheckDue: Bool {
        guard let lastCheckDate else { return true }
        return Date().timeIntervalSince(lastCheckDate) >= Self.checkInterval
    }

    // MARK: Checking

    /// Asks GitHub for the latest release. Background checks never surface
    /// errors or "up to date"; they only move to `.available`.
    func checkForUpdates(userInitiated: Bool) async {
        guard !isBusy else { return }
        let previous = state
        if userInitiated { state = .checking }
        do {
            let release = try await UpdateChecker.latestRelease()
            lastCheckDate = Date()
            if let release, let current = SemanticVersion(currentVersion), release.version > current {
                availableRelease = release
                state = .available(release)
            } else {
                availableRelease = nil
                if userInitiated {
                    state = .upToDate
                } else if case .available = previous {
                    state = .idle
                }
            }
        } catch {
            if userInitiated {
                state = .failed(Self.message(for: error))
            } else {
                state = previous == .checking ? .idle : previous
            }
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case UpdateChecker.Failure.network:
            String(localized: "Couldn't reach GitHub to check for updates. Check your internet connection and try again.")
        case UpdateChecker.Failure.rateLimited:
            String(localized: "GitHub is limiting update checks right now. Try again in an hour.")
        case UpdateChecker.Failure.unusable:
            String(localized: "The latest release doesn't include a Mac download yet.")
        default:
            String(localized: "Checking for updates failed. Try again later.")
        }
    }

    // MARK: Installing

    /// Downloads, verifies and installs `availableRelease`, then quits so the
    /// swap script can relaunch the new version.
    func installUpdate() async {
        guard let release = availableRelease, !isBusy else { return }
        let bundleURL = Bundle.main.bundleURL
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("PilothouseUpdate-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

            state = .downloading(progress: 0)
            let dmg = staging.appendingPathComponent(release.dmgName)
            try await UpdateInstaller.download(release.dmgURL, to: dmg, expectedSize: release.dmgSize) { [weak self] fraction in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(progress: fraction)
            }
            state = .downloading(progress: 1)

            state = .installing
            let checksumText = try await UpdateInstaller.fetchText(release.checksumURL)
            guard let expected = ChecksumFile.digest(from: checksumText, fileName: release.dmgName) else {
                throw UpdateInstaller.Failure.checksumMissing
            }
            let actual = try await UpdateInstaller.sha256Hex(of: dmg)
            guard actual == expected else { throw UpdateInstaller.Failure.checksumMismatch }

            let stagedApp = try await UpdateInstaller.extractApp(fromDMG: dmg, into: staging)
            try? fileManager.removeItem(at: dmg)
            try await UpdateInstaller.verify(stagedApp: stagedApp)

            guard UpdateInstaller.canReplace(bundleAt: bundleURL) else {
                NSWorkspace.shared.open(release.pageURL)
                throw UpdateInstaller.Failure.cannotReplace
            }
            let backup = staging.appendingPathComponent("Previous-\(bundleURL.lastPathComponent)")
            try UpdateInstaller.launchSwap(
                pid: ProcessInfo.processInfo.processIdentifier,
                oldBundle: bundleURL,
                newBundle: stagedApp,
                backup: backup
            )
            NSApp.terminate(nil)
        } catch {
            try? fileManager.removeItem(at: staging)
            state = .failed(Self.installMessage(for: error))
        }
    }

    /// Opens the release page (manual fallback, e.g. a "Download" button).
    func openReleasePage() {
        NSWorkspace.shared.open(availableRelease?.pageURL ?? UpdateChecker.releasesPageURL)
    }

    private static func installMessage(for error: Error) -> String {
        if let failure = error as? UpdateInstaller.Failure { return failure.message }
        return String(localized: "Installing the update failed. Try again, or download it from GitHub.")
    }
}
