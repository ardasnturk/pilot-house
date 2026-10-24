import Foundation
import PilothouseKit
@testable import PilothouseHost

/// A throw-away home folder for one test.
struct TemporaryHome {
    let url: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pilothouse-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.resolvingSymlinksInPath()
    }

    var path: String { url.path }

    @discardableResult
    func makeDirectory(_ relative: String) throws -> URL {
        let directory = url.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func write(_ relative: String, _ contents: String = "x") throws {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum Fixtures {
    static func url(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    static func lines(_ name: String) throws -> [String] {
        try String(contentsOf: url(name), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// Copies FakeClaude to `directory` and makes it executable.
    static func installFakeClaude(in directory: URL) throws -> String {
        let destination = directory.appendingPathComponent("fake-claude")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url("fake-claude.sh"), to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination.path
    }
}

/// Launches FakeClaude through the production argument builder.
struct FakeClaudeLauncher: ClaudeLauncher {
    let executable: String
    let argsLog: URL

    func launch(_ options: ClaudeLaunchOptions) async throws -> ChildProcess {
        var environment = ClaudeCommand.environment(base: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": options.workingDirectory,
        ], apiKey: nil)
        environment["FAKE_CLAUDE_ARGS_LOG"] = argsLog.path
        return try ChildProcess.spawn(
            executable: executable,
            arguments: ClaudeCommand.arguments(for: options),
            environment: environment,
            workingDirectory: options.workingDirectory
        )
    }
}

/// Static Mac status for tests.
struct TestStatusProvider: MacStatusProviding {
    func macStatus() async -> MacStatus {
        MacStatus(
            macName: "Test Mac", sleepPrevented: true, lidClosedModeEnabled: false,
            claude: ClaudeCLIStatus(installed: true, path: "/fake/claude", version: "0.0.0-fake"),
            tailscale: .notInstalled, addresses: [], port: 47823, activeSessionCount: 0, bypassPermissionsAllowed: false
        )
    }
}

/// Collects events from a session stream until a predicate matches.
func collect(
    _ stream: AsyncStream<SequencedEvent>,
    timeout: Double = 20,
    until done: @escaping @Sendable ([SequencedEvent]) -> Bool
) async throws -> [SequencedEvent] {
    try await withTimeout(seconds: timeout) {
        var events: [SequencedEvent] = []
        for await event in stream {
            events.append(event)
            if done(events) { break }
        }
        return events
    }
}

extension SessionEvent {
    var isResult: Bool { if case .result = self { true } else { false } }

    var notice: SystemNotice? { if case .systemNotice(let notice) = self { notice } else { nil } }
}

extension Array where Element == SequencedEvent {
    var persisted: [SequencedEvent] { filter { !$0.ephemeral } }
    var resultCount: Int { filter { $0.event.isResult }.count }
}
