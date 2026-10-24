import CryptoKit
import Foundation
import Security

/// Blocking / shell-tool side of the updater. Everything here runs off the
/// main actor; `AppUpdater` only awaits it.
enum UpdateInstaller {
    enum Failure: Error {
        case network
        case httpStatus(Int)
        case checksumMissing
        case checksumMismatch
        case mountFailed(String)
        case appMissingInImage
        case copyFailed(String)
        case signatureInvalid(String)
        case teamMismatch
        case runningAppUnsigned
        case gatekeeperRejected(String)
        case cannotReplace
        case launchFailed

        /// User-visible explanation (English, extractable).
        var message: String {
            switch self {
            case .network:
                String(localized: "The update couldn't be downloaded. Check your internet connection and try again.")
            case .httpStatus:
                String(localized: "GitHub returned an error while downloading the update. Try again later.")
            case .checksumMissing:
                String(localized: "The update's checksum file couldn't be read.")
            case .checksumMismatch:
                String(localized: "The downloaded update is damaged (checksum mismatch). Nothing was installed.")
            case .mountFailed:
                String(localized: "The update's disk image couldn't be opened.")
            case .appMissingInImage:
                String(localized: "The update's disk image doesn't contain Pilothouse.")
            case .copyFailed:
                String(localized: "The update couldn't be copied from its disk image.")
            case .signatureInvalid:
                String(localized: "The update's code signature is invalid. Nothing was installed.")
            case .teamMismatch:
                String(localized: "The update isn't signed by the same developer as this copy of Pilothouse. Nothing was installed.")
            case .runningAppUnsigned:
                String(localized: "This copy of Pilothouse isn't signed with a Developer ID, so it can't update itself.")
            case .gatekeeperRejected:
                String(localized: "macOS Gatekeeper rejected the update. Nothing was installed.")
            case .cannotReplace:
                String(localized: "Pilothouse can't replace itself in its current location. The download page has been opened in your browser.")
            case .launchFailed:
                String(localized: "The installer couldn't be started. Nothing was changed.")
            }
        }
    }

    // MARK: Download

    /// Downloads `url` into `directory`, reporting progress (0...1) on the main actor.
    static func download(
        _ url: URL,
        to destination: URL,
        expectedSize: Int?,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let delegate = DownloadDelegate(destination: destination, expectedSize: expectedSize, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    static func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.network
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.httpStatus(http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Streams the file through SHA-256 so large images need no full read into memory.
    static func sha256Hex(of file: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    // MARK: Disk image

    /// Mounts the DMG, copies `<appName>.app` into `staging`, detaches. Returns the staged app.
    static func extractApp(fromDMG dmg: URL, into staging: URL, appName: String = "Pilothouse") async throws -> URL {
        let attach = try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg.path])
        guard attach.status == 0 else { throw Failure.mountFailed(attach.errorText) }
        guard let mountPoint = mountPoint(fromAttachPlist: attach.output) else {
            throw Failure.mountFailed("no mount point")
        }
        let result: Result<URL, Error>
        do {
            let source = URL(fileURLWithPath: mountPoint).appendingPathComponent("\(appName).app")
            guard FileManager.default.fileExists(atPath: source.path) else { throw Failure.appMissingInImage }
            let target = staging.appendingPathComponent("\(appName).app")
            let copy = try await run("/usr/bin/ditto", [source.path, target.path])
            guard copy.status == 0 else { throw Failure.copyFailed(copy.errorText) }
            result = .success(target)
        } catch {
            result = .failure(error)
        }
        // Detach whether or not the copy worked; force as a fallback.
        let detach = try? await run("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"])
        if detach?.status != 0 {
            _ = try? await run("/usr/bin/hdiutil", ["detach", mountPoint, "-force", "-quiet"])
        }
        return try result.get()
    }

    static func mountPoint(fromAttachPlist data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        return entities.lazy.compactMap { $0["mount-point"] as? String }.first
    }

    // MARK: Verification

    /// `codesign --verify --deep --strict`, same Team ID as the running app, Gatekeeper assessment.
    static func verify(stagedApp app: URL) async throws {
        guard let ownTeam = runningTeamIdentifier() else { throw Failure.runningAppUnsigned }
        let verify = try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verify.status == 0 else { throw Failure.signatureInvalid(verify.errorText) }
        guard let stagedTeam = teamIdentifier(ofAppAt: app), stagedTeam == ownTeam else { throw Failure.teamMismatch }
        let assess = try await run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard assess.status == 0 else { throw Failure.gatekeeperRejected(assess.errorText) }
    }

    static func runningTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    static func teamIdentifier(ofAppAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: Replacing the running bundle

    /// Whether the running bundle can be swapped in place: not on a mounted
    /// image, not translocated, and its parent folder writable (moving the
    /// bundle and creating the new one only need the parent; the bundle's own
    /// permission bits can read as non-writable under App Management).
    static func canReplace(bundleAt bundle: URL) -> Bool {
        let path = bundle.standardizedFileURL.path
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") { return false }
        if let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]), values.volumeIsReadOnly == true {
            return false
        }
        return FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    /// Script run detached after the app quits: wait for `pid`, move the old
    /// bundle aside, copy the new one in, strip quarantine, relaunch. If the
    /// copy fails the old bundle is put back.
    static let swapScript = """
    pid="$1"; old="$2"; new="$3"; backup="$4"
    i=0
    while /bin/kill -0 "$pid" 2>/dev/null; do
      i=$((i+1)); [ "$i" -gt 600 ] && exit 1
      /bin/sleep 0.2
    done
    /bin/mv "$old" "$backup" || { /usr/bin/open "$old"; exit 1; }
    if /usr/bin/ditto "$new" "$old"; then
      /usr/bin/xattr -dr com.apple.quarantine "$old" 2>/dev/null
      /usr/bin/open "$old"
      /bin/rm -rf "$new"
    else
      /bin/rm -rf "$old"
      /bin/mv "$backup" "$old"
      /usr/bin/open "$old"
    fi
    """

    /// Spawns the swap script in its own process group with stdio on
    /// /dev/null, so it survives this app's termination.
    static func launchSwap(pid: pid_t, oldBundle: URL, newBundle: URL, backup: URL) throws {
        let arguments = ["/usr/bin/nohup", "/bin/sh", "-c", swapScript, "pilothouse-update",
                         String(pid), oldBundle.path, newBundle.path, backup.path]
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        let cEnvironment: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { cEnvironment.forEach { free($0) } }

        var child: pid_t = 0
        let result = posix_spawn(&child, arguments[0], &actions, &attributes, cArguments, cEnvironment)
        guard result == 0 else { throw Failure.launchFailed }
    }

    // MARK: Process helper

    struct ProcessResult: Sendable {
        let status: Int32
        let output: Data
        let errorOutput: Data
        var errorText: String {
            String(decoding: errorOutput.isEmpty ? output : errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Runs a tool to completion off the main actor. Output goes to temporary
    /// files so a chatty tool can never block on a full pipe.
    static func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let base = fileManager.temporaryDirectory.appendingPathComponent("pilothouse-run-\(UUID().uuidString)")
            let outURL = base.appendingPathExtension("out")
            let errURL = base.appendingPathExtension("err")
            fileManager.createFile(atPath: outURL.path, contents: nil)
            fileManager.createFile(atPath: errURL.path, contents: nil)
            defer {
                try? fileManager.removeItem(at: outURL)
                try? fileManager.removeItem(at: errURL)
            }
            let outHandle = try FileHandle(forWritingTo: outURL)
            let errHandle = try FileHandle(forWritingTo: errURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outHandle
            process.standardError = errHandle
            try process.run()
            process.waitUntilExit()
            try? outHandle.close()
            try? errHandle.close()
            return ProcessResult(
                status: process.terminationStatus,
                output: (try? Data(contentsOf: outURL)) ?? Data(),
                errorOutput: (try? Data(contentsOf: errURL)) ?? Data()
            )
        }.value
    }
}

/// Bridges a delegate-based download task (needed for byte progress) to async.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let expectedSize: Int?
    private let progress: @MainActor @Sendable (Double) -> Void
    private var lastReported = -1.0
    private var moveError: Error?
    private var _continuation: CheckedContinuation<Void, Error>?

    var continuation: CheckedContinuation<Void, Error>? {
        get { lock.withLock { _continuation } }
        set { lock.withLock { _continuation = newValue } }
    }

    init(destination: URL, expectedSize: Int?, progress: @escaping @MainActor @Sendable (Double) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { _continuation = nil }
            return _continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(expectedSize ?? 0)
        guard total > 0 else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(total))
        let shouldReport = lock.withLock { () -> Bool in
            guard fraction - lastReported >= 0.01 || fraction >= 1 else { return false }
            lastReported = fraction
            return true
        }
        guard shouldReport else { return }
        let progress = progress
        Task { @MainActor in progress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            lock.withLock { moveError = UpdateInstaller.Failure.httpStatus(http.statusCode) }
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            finish(.failure(UpdateInstaller.Failure.network))
            return
        }
        if let moveError = lock.withLock({ moveError }) {
            finish(.failure(moveError))
        } else {
            finish(.success(()))
        }
    }
}
