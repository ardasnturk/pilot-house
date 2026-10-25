import Foundation
#if canImport(os)
import os
#endif

/// Minimal logging facade: `os.Logger` on Apple platforms, stderr elsewhere.
///
/// Message bodies never contain secrets (keys, tokens, API keys); callers are
/// responsible for that. Debug messages are compiled out of Linux builds.
public struct RemoteCodeLog: Sendable {
    public let category: String

    #if canImport(os)
    private let logger: Logger
    #endif

    public init(_ category: String) {
        self.category = category
        #if canImport(os)
        logger = Logger(subsystem: "com.ardasenturk.Pilothouse", category: category)
        #endif
    }

    public func debug(_ message: @autoclosure () -> String) {
        #if canImport(os)
        let text = message()
        logger.debug("\(text, privacy: .public)")
        #endif
    }

    public func info(_ message: @autoclosure () -> String) {
        let text = message()
        #if canImport(os)
        logger.info("\(text, privacy: .public)")
        #else
        Self.write("INFO", category, text)
        #endif
    }

    public func error(_ message: @autoclosure () -> String) {
        let text = message()
        #if canImport(os)
        logger.error("\(text, privacy: .public)")
        #else
        Self.write("ERROR", category, text)
        #endif
    }

    #if !canImport(os)
    private static func write(_ level: String, _ category: String, _ text: String) {
        guard ProcessInfo.processInfo.environment["REMOTECODE_LOG"] != nil else { return }
        FileHandle.standardError.write(Data("[\(level)] \(category): \(text)\n".utf8))
    }
    #endif
}
