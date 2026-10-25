import Foundation
import os

/// Privileged launchd daemon registered with `SMAppService.daemon`.
///
/// Security properties (docs/SECURITY.md):
/// * accepts XPC connections only from the Remote Code app signed by team 5JMD3VSD7N;
/// * runs exactly one fixed command, `/usr/bin/pmset -a disablesleep <0|1>`,
///   with no user-controlled arguments;
/// * reverts `disablesleep` to 0 when the app's connection goes away (quit or
///   crash), so the Mac never stays sleepless by accident.
/// `@unchecked Sendable`: XPC calls arrive on arbitrary queues; all mutable
/// state is guarded by `lock`.
final class HelperService: NSObject, PilothouseHelperProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    private let logger = Logger(subsystem: HelperConstants.machServiceName, category: "helper")
    private let lock = NSLock()
    private var activeConnections = 0
    private var enabledByConnection = Set<ObjectIdentifier>()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(HelperConstants.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: PilothouseHelperProtocol.self)
        connection.exportedObject = ConnectionProxy(service: self, connection: connection)
        let key = ObjectIdentifier(connection)
        connection.invalidationHandler = { [weak self] in
            self?.connectionEnded(key)
        }
        lock.withLock { activeConnections += 1 }
        connection.resume()
        return true
    }

    func setSleepDisabled(_ disabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        reply(false, "Use the connection-bound proxy")
    }

    func isSleepDisabled(withReply reply: @escaping (Bool) -> Void) {
        reply(Self.readSleepDisabled())
    }

    func helperVersion(withReply reply: @escaping (String) -> Void) {
        reply(HelperConstants.version)
    }

    fileprivate func set(_ disabled: Bool, for connection: ObjectIdentifier) -> (Bool, String?) {
        let result = Self.runPmset(disabled)
        if result.0 {
            lock.withLock {
                if disabled { enabledByConnection.insert(connection) } else { enabledByConnection.remove(connection) }
            }
        }
        logger.info("disablesleep \(disabled ? 1 : 0, privacy: .public): \(result.0 ? "ok" : (result.1 ?? "failed"), privacy: .public)")
        return result
    }

    private func connectionEnded(_ key: ObjectIdentifier) {
        let (wasEnabled, remaining) = lock.withLock { () -> (Bool, Int) in
            activeConnections -= 1
            return (enabledByConnection.remove(key) != nil, activeConnections)
        }
        if wasEnabled {
            _ = Self.runPmset(false)
            logger.info("App disconnected; disablesleep reverted to 0")
        }
        if remaining <= 0 {
            // Nothing left to do; launchd starts us again on demand.
            exit(0)
        }
    }

    static func runPmset(_ disabled: Bool) -> (Bool, String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (false, message.isEmpty ? "pmset exited with \(process.terminationStatus)" : message)
        }
        return (true, nil)
    }

    static func readSleepDisabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            return false
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.first == "SleepDisabled" && parts.last == "1"
        }
    }
}

/// Binds calls to the connection they came from, so a crash of that client
/// reverts exactly what it enabled.
final class ConnectionProxy: NSObject, PilothouseHelperProtocol, @unchecked Sendable {
    private weak var service: HelperService?
    private let key: ObjectIdentifier

    init(service: HelperService, connection: NSXPCConnection) {
        self.service = service
        key = ObjectIdentifier(connection)
    }

    func setSleepDisabled(_ disabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        guard let service else { return reply(false, "Helper unavailable") }
        let (ok, message) = service.set(disabled, for: key)
        reply(ok, message)
    }

    func isSleepDisabled(withReply reply: @escaping (Bool) -> Void) {
        reply(HelperService.readSleepDisabled())
    }

    func helperVersion(withReply reply: @escaping (String) -> Void) {
        reply(HelperConstants.version)
    }
}

let service = HelperService()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = service
listener.resume()
RunLoop.main.run()
