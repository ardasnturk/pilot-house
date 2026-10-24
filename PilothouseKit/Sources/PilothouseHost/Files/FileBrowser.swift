import Foundation
import PilothouseKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Confines paths to the user's home folder (prompt §4.6).
///
/// Paths are tilde-expanded, made absolute relative to home, standardised
/// (`..` removed) and symlink-resolved before the containment check, so neither
/// `~/../../etc` nor a symlink `~/link → /etc` escapes.
public struct PathSandbox: Sendable {
    /// The resolved home folder.
    public let home: URL

    public init(homeDirectory: String = NSHomeDirectory()) {
        home = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Resolves `path` (absolute, `~`-relative or relative to home).
    /// Throws `pathOutsideHome` if the result is not inside home.
    public func resolve(_ path: String?) throws -> URL {
        let raw = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let absolute: String
        if raw.isEmpty || raw == "~" {
            absolute = home.path
        } else if raw.hasPrefix("~/") {
            absolute = home.path + "/" + raw.dropFirst(2)
        } else if raw.hasPrefix("/") {
            absolute = raw
        } else {
            absolute = home.path + "/" + raw
        }
        let resolved = URL(fileURLWithPath: absolute).standardizedFileURL.resolvingSymlinksInPath()
        guard isInside(resolved) else {
            throw ErrorPayload(code: .pathOutsideHome, message: "Only folders inside your home folder can be used.")
        }
        return resolved
    }

    public func isInside(_ url: URL) -> Bool {
        let rootComponents = home.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        return components.count >= rootComponents.count && Array(components.prefix(rootComponents.count)) == rootComponents
    }
}

/// Lists directories for the folder picker.
public struct FileBrowser: Sendable {
    public let sandbox: PathSandbox
    public var entryLimit: Int

    public init(sandbox: PathSandbox, entryLimit: Int = 2_000) {
        self.sandbox = sandbox
        self.entryLimit = entryLimit
    }

    public func list(_ request: ListDirectory) throws -> DirectoryListing {
        let url = try sandbox.resolve(request.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ErrorPayload(code: .notFound, message: "The folder \(displayPath(url)) does not exist.")
        }
        guard isDirectory.boolValue else {
            throw ErrorPayload(code: .notADirectory, message: "\(displayPath(url)) is not a folder.")
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        } catch {
            throw privacyError(for: url, underlying: error) ?? ErrorPayload(
                code: .internalError,
                message: "Could not read \(displayPath(url)): \(error.localizedDescription)"
            )
        }

        var entries: [FileNode] = []
        for item in contents {
            let values = try? item.resourceValues(forKeys: Set(keys))
            let name = item.lastPathComponent
            let hidden = name.hasPrefix(".") || values?.isHidden == true
            if hidden && !request.showHidden { continue }
            let isSymlink = values?.isSymbolicLink ?? false
            var directory = values?.isDirectory ?? false
            if isSymlink {
                // Show links to folders inside home as folders; others as plain entries.
                let target = item.resolvingSymlinksInPath()
                var targetIsDirectory: ObjCBool = false
                directory = sandbox.isInside(target)
                    && FileManager.default.fileExists(atPath: target.path, isDirectory: &targetIsDirectory)
                    && targetIsDirectory.boolValue
            }
            let path = url.appendingPathComponent(name).path
            entries.append(FileNode(
                name: name,
                path: path,
                isDirectory: directory,
                isHidden: hidden,
                isSymbolicLink: isSymlink,
                isGitRepository: directory && FileManager.default.fileExists(atPath: path + "/.git"),
                size: directory ? nil : values?.fileSize.map(Int64.init),
                modifiedAt: values?.contentModificationDate
            ))
        }
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let truncated = entries.count > entryLimit
        if truncated { entries = Array(entries.prefix(entryLimit)) }

        let isHome = url.standardizedFileURL.path == sandbox.home.standardizedFileURL.path
        return DirectoryListing(
            path: url.path,
            homePath: sandbox.home.path,
            parentPath: isHome ? nil : url.deletingLastPathComponent().path,
            isGitRepository: FileManager.default.fileExists(atPath: url.path + "/.git"),
            entries: entries,
            truncated: truncated
        )
    }

    /// Validates a working directory for a new session.
    public func validateWorkingDirectory(_ path: String) throws -> URL {
        let url = try sandbox.resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ErrorPayload(code: .notADirectory, message: "\(displayPath(url)) is not a folder.")
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: url.path)) == nil, access(url.path, R_OK) != 0 {
            throw privacyError(for: url, underlying: nil)
                ?? ErrorPayload(code: .internalError, message: "Pilothouse cannot read \(displayPath(url)).")
        }
        return url
    }

    /// Maps permission failures to an actionable macOS privacy (TCC) message.
    func privacyError(for url: URL, underlying: Error?) -> ErrorPayload? {
        if let underlying {
            let nsError = underlying as NSError
            let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? nsError.code
            let isPermission = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError)
                || posix == Int(EPERM) || posix == Int(EACCES)
            guard isPermission else { return nil }
        }
        let relative = url.path.dropFirst(sandbox.home.path.count).split(separator: "/").first.map(String.init)
        let folder: String
        switch relative {
        case "Desktop": folder = "Desktop Folder"
        case "Documents": folder = "Documents Folder"
        case "Downloads": folder = "Downloads Folder"
        default:
            return ErrorPayload(
                code: .privacyPermissionRequired,
                message: "macOS blocked access to \(displayPath(url)). On your Mac open System Settings → Privacy & Security → Full Disk Access and turn on Pilothouse."
            )
        }
        return ErrorPayload(
            code: .privacyPermissionRequired,
            message: "macOS blocked access to \(displayPath(url)). On your Mac open System Settings → Privacy & Security → Files & Folders → Pilothouse and turn on \"\(folder)\"."
        )
    }

    func displayPath(_ url: URL) -> String {
        let home = sandbox.home.path
        guard url.path.hasPrefix(home) else { return url.path }
        let rest = url.path.dropFirst(home.count)
        return rest.isEmpty ? "~" : "~\(rest)"
    }
}
