import Foundation
import RemoteCodeKit
import Testing
@testable import RemoteCodeHost

@Suite struct PathSandboxTests {
    @Test func resolvesHomeRelativePaths() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.makeDirectory("Developer/app")
        let sandbox = PathSandbox(homeDirectory: home.path)
        #expect(try sandbox.resolve(nil).path == home.path)
        #expect(try sandbox.resolve("~").path == home.path)
        #expect(try sandbox.resolve("~/Developer/app").path == home.path + "/Developer/app")
        #expect(try sandbox.resolve("Developer").path == home.path + "/Developer")
        #expect(try sandbox.resolve(home.path + "/Developer/./app/../app").path == home.path + "/Developer/app")
    }

    @Test(arguments: ["/", "/etc", "~/..", "~/../../etc/passwd", "../", "Developer/../../.."])
    func refusesEscapes(_ path: String) throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.makeDirectory("Developer")
        let sandbox = PathSandbox(homeDirectory: home.path)
        #expect(throws: ErrorPayload.self) { try sandbox.resolve(path) }
    }

    @Test func refusesSymlinksPointingOutside() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try FileManager.default.createSymbolicLink(atPath: home.path + "/escape", withDestinationPath: "/etc")
        try home.makeDirectory("inside")
        try FileManager.default.createSymbolicLink(atPath: home.path + "/shortcut", withDestinationPath: home.path + "/inside")
        let sandbox = PathSandbox(homeDirectory: home.path)
        #expect(throws: ErrorPayload.self) { try sandbox.resolve("~/escape") }
        #expect(throws: ErrorPayload.self) { try sandbox.resolve("~/escape/../etc") }
        #expect(try sandbox.resolve("~/shortcut").path == home.path + "/inside")
    }

    @Test func prefixSiblingIsNotInside() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let sibling = home.path + "-evil"
        try FileManager.default.createDirectory(atPath: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: sibling) }
        let sandbox = PathSandbox(homeDirectory: home.path)
        #expect(throws: ErrorPayload.self) { try sandbox.resolve(sibling) }
    }
}

@Suite struct FileBrowserTests {
    @Test func listsFoldersFirstHidesDotfilesAndMarksRepositories() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.makeDirectory("Projects/app/.git")
        try home.makeDirectory("Projects/notes")
        try home.makeDirectory("Projects/.cache")
        try home.write("Projects/readme.md", "hello")
        try home.write("Projects/.env", "SECRET=1")
        let browser = FileBrowser(sandbox: PathSandbox(homeDirectory: home.path))

        let listing = try browser.list(ListDirectory(path: "~/Projects"))
        #expect(listing.path == home.path + "/Projects")
        #expect(listing.parentPath == home.path)
        #expect(listing.displayPath == "~/Projects")
        #expect(listing.entries.map(\.name) == ["app", "notes", "readme.md"])
        #expect(listing.entries[0].isGitRepository)
        #expect(!listing.entries[1].isGitRepository)
        #expect(listing.entries[2].size == 5)

        let hidden = try browser.list(ListDirectory(path: "~/Projects", showHidden: true))
        #expect(hidden.entries.map(\.name) == [".cache", "app", "notes", ".env", "readme.md"])
        #expect(hidden.entries.first?.isHidden == true)
    }

    @Test func homeHasNoParent() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let browser = FileBrowser(sandbox: PathSandbox(homeDirectory: home.path))
        #expect(try browser.list(ListDirectory()).parentPath == nil)
    }

    @Test func errorsAreSpecific() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.write("file.txt")
        let browser = FileBrowser(sandbox: PathSandbox(homeDirectory: home.path))
        do {
            _ = try browser.list(ListDirectory(path: "~/missing"))
            Issue.record("Expected notFound")
        } catch let error as ErrorPayload {
            #expect(error.code == .notFound)
        }
        do {
            _ = try browser.list(ListDirectory(path: "~/file.txt"))
            Issue.record("Expected notADirectory")
        } catch let error as ErrorPayload {
            #expect(error.code == .notADirectory)
        }
        #expect(throws: ErrorPayload.self) { try browser.validateWorkingDirectory("~/file.txt") }
    }

    @Test func entryLimitTruncates() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        for index in 0..<12 { try home.write("many/f\(index).txt") }
        var browser = FileBrowser(sandbox: PathSandbox(homeDirectory: home.path))
        browser.entryLimit = 5
        let listing = try browser.list(ListDirectory(path: "~/many"))
        #expect(listing.entries.count == 5)
        #expect(listing.truncated)
    }

    @Test func privacyErrorsNameTheRightSetting() throws {
        let browser = FileBrowser(sandbox: PathSandbox(homeDirectory: "/Users/demo"))
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let desktop = browser.privacyError(for: URL(fileURLWithPath: "/Users/demo/Desktop/x"), underlying: denied)
        #expect(desktop?.code == .privacyPermissionRequired)
        #expect(desktop?.message.contains("Desktop Folder") == true)
        let library = browser.privacyError(for: URL(fileURLWithPath: "/Users/demo/Library/Mail"), underlying: denied)
        #expect(library?.message.contains("Full Disk Access") == true)
        let other = browser.privacyError(for: URL(fileURLWithPath: "/Users/demo/x"), underlying: NSError(domain: NSCocoaErrorDomain, code: 4))
        #expect(other == nil)
    }

    @Test func createsFolderAndReturnsParentListing() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.makeDirectory("Projects")
        let browser = FileBrowser(sandbox: PathSandbox(homeDirectory: home.path))

        let listing = try browser.createDirectory(CreateDirectory(parent: "~/Projects", name: "  new app "))
        #expect(listing.path == home.path + "/Projects")
        #expect(listing.entries.map(\.name) == ["new app"])
        #expect(listing.entries[0].isDirectory)
    }

    @Test(arguments: ["", "  ", ".hidden", "..", "a/b", "../escape", "a:b", String(repeating: "x", count: 256)])
    func rejectsInvalidFolderNames(_ name: String) throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let browser = FileBrowser(sandbox: PathSandbox(homeDirectory: home.path))
        do {
            _ = try browser.createDirectory(CreateDirectory(parent: "~", name: name))
            Issue.record("Expected invalidName for \(name)")
        } catch let error as ErrorPayload {
            #expect(error.code == .invalidName)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    @Test func refusesExistingNamesAndParentsOutsideHome() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.makeDirectory("taken")
        try FileManager.default.createSymbolicLink(atPath: home.path + "/escape", withDestinationPath: "/tmp")
        let browser = FileBrowser(sandbox: PathSandbox(homeDirectory: home.path))
        do {
            _ = try browser.createDirectory(CreateDirectory(parent: "~", name: "taken"))
            Issue.record("Expected alreadyExists")
        } catch let error as ErrorPayload {
            #expect(error.code == .alreadyExists)
        }
        for parent in ["/tmp", "~/..", "~/escape"] {
            do {
                _ = try browser.createDirectory(CreateDirectory(parent: parent, name: "pwned"))
                Issue.record("Expected pathOutsideHome for \(parent)")
            } catch let error as ErrorPayload {
                #expect(error.code == .pathOutsideHome)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: "/tmp/pwned"))
    }
}

@Suite struct EventLogTests {
    @Test func appendsLoadsAndContinuesSequence() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let url = home.url.appendingPathComponent("sessions/s.jsonl")
        let log = EventLog(url: url)
        let first = try log.append(.userMessage(.init(text: "hi")))
        let second = try log.append(.assistantMessage(.init(blockId: "b", text: "hello")))
        #expect(first.seq == 1)
        #expect(second.seq == 2)
        log.close()

        let reopened = EventLog(url: url)
        #expect(try reopened.lastSeq == 2)
        #expect(try reopened.events(from: 2).map(\.seq) == [2])
        #expect(try reopened.append(.systemNotice(.init(kind: "k", level: .info, text: "t"))).seq == 3)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func recoversFromATornLastLine() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let url = home.url.appendingPathComponent("s.jsonl")
        let log = EventLog(url: url)
        _ = try log.append(.userMessage(.init(text: "one")))
        log.close()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"seq":2,"ts":"2026-01-01T00:00:00.000Z","event":{"type":"userMes"#.utf8))
        try handle.close()

        let reopened = EventLog(url: url)
        #expect(try reopened.lastSeq == 1)
        #expect(try reopened.append(.userMessage(.init(text: "two"))).seq == 2)
        reopened.close()
        let final = EventLog(url: url)
        #expect(try final.events(from: 1).map(\.seq) == [1, 2])
    }

    @Test func sessionStorePersistsRecords() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let url = home.url.appendingPathComponent("sessions.json")
        let store = SessionStore(url: url)
        let summary = SessionSummary(id: "a", cwd: "/x", title: "T", createdAt: Date(), updatedAt: Date())
        await store.upsert(SessionRecord(summary: summary, established: true, alwaysAllowed: ["Bash(npm)"]))
        let reloaded = SessionStore(url: url)
        let record = await reloaded.record("a")
        #expect(record?.established == true)
        #expect(record?.alwaysAllowed == ["Bash(npm)"])
        await reloaded.remove("a")
        #expect(await SessionStore(url: url).all.isEmpty)
    }
}
