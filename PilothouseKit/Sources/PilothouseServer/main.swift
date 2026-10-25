import Dispatch
import Foundation
import PilothouseHost
import PilothouseKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// pilothouse-server: the Pilothouse host without the Mac app (D-110).

let command = CommandLine.arguments.dropFirst().first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "serve"
let arguments = Array(CommandLine.arguments.dropFirst(CommandLine.arguments.dropFirst().first == command ? 2 : 1))

do {
    switch command {
    case "serve":
        let options = try ServerOptions(environment: ProcessInfo.processInfo.environment, arguments: arguments)
        try await Commands.serve(options)
    case "pair":
        let wait = !arguments.contains("--no-wait")
        try Commands.pair(try clientOptions(arguments), wait: wait)
    case "status":
        try Commands.status(try clientOptions(arguments))
    case "health":
        _ = try ControlClient(url: try clientOptions(arguments).controlURL).request("GET", "/health", as: ControlMessage.self)
    case "devices":
        try Commands.devices(try clientOptions(arguments))
    case "revoke":
        guard let id = arguments.first else { throw OptionError("Usage: pilothouse-server revoke ID (see `pilothouse-server devices`).") }
        try Commands.revoke(id, options: try clientOptions(Array(arguments.dropFirst())))
    case "avahi-service":
        try Commands.avahiService(try clientOptions(arguments))
    case "version", "--version":
        Console.log(LinuxHost.serverVersion)
    case "help", "--help", "-h":
        Console.log(ServerOptions.usage)
    default:
        throw OptionError("Unknown command \(command).\n\n\(ServerOptions.usage)")
    }
} catch {
    Console.error("pilothouse-server: \(error)")
    exit(1)
}

/// Options for the client commands: the environment plus `--data-dir`, if given.
func clientOptions(_ arguments: [String]) throws -> ServerOptions {
    var dataDirectory: [String] = []
    if let index = arguments.firstIndex(of: "--data-dir"), index + 1 < arguments.count {
        dataDirectory = Array(arguments[index...index + 1])
    }
    return try ServerOptions(environment: ProcessInfo.processInfo.environment, arguments: dataDirectory)
}

enum Commands {
    static func serve(_ options: ServerOptions) async throws {
        signal(SIGPIPE, SIG_IGN)
        let host = LinuxHost(options: options)
        let signals = DispatchQueue(label: "com.ardasenturk.Pilothouse.signals")
        var sources: [any DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: signals)
            source.setEventHandler {
                Console.log("Stopping…")
                Task {
                    await host.shutdown()
                    exit(0)
                }
            }
            source.resume()
            sources.append(source)
        }
        try await host.start()
        // Keep the signal sources and the process alive.
        while !sources.isEmpty {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    static func pair(_ options: ServerOptions, wait: Bool) throws {
        let client = try ControlClient(url: options.controlURL)
        let before = Set(try client.request("GET", "/devices", as: [ControlDevice].self).map(\.id))
        let pairing = try client.request("POST", "/pair", as: ControlPairing.self)
        let minutes = max(1, (pairing.expiresAt - Int(Date().timeIntervalSince1970) + 30) / 60)
        Console.log("""

            Pair your iPhone or iPad with “\(options.name)”:
              1. Open Pilothouse on the phone → Pair with Your Mac → Scan the Pairing Code.
                 (Or: Paste a Pairing Link Instead, and paste the link below.)
              2. Both screens show the same verification code: \(pairing.verificationCode)

            """)
        if let qr = QRCode.render(pairing.link) {
            Console.log(qr)
        } else {
            Console.log("(Install `qrencode` to see a QR code here.)\n")
        }
        Console.log("""
            Link:      \(pairing.link)
            Addresses: \(pairing.addresses.map { "\($0):\(pairing.port)" }.joined(separator: ", ").ifEmpty("none — set PILOTHOUSE_ADDRESSES"))
            The code works once and for \(minutes) minutes.
            """)
        guard wait else { return }
        Console.log("\nWaiting for the phone… (Ctrl-C to stop waiting)")
        while Int(Date().timeIntervalSince1970) < pairing.expiresAt {
            Thread.sleep(forTimeInterval: 2)
            let devices = try client.request("GET", "/devices", as: [ControlDevice].self)
            if let added = devices.first(where: { !before.contains($0.id) }) {
                Console.log("✓ Paired with \(added.name) (\(added.platform)). You can start a chat on the phone now.")
                return
            }
        }
        Console.log("The code expired. Run `pilothouse-server pair` again for a new one.")
    }

    static func status(_ options: ServerOptions) throws {
        let status = try ControlClient(url: options.controlURL).request("GET", "/status", as: ControlStatus.self)
        var lines = [
            "\(status.name) — Pilothouse \(status.version)",
            "  Addresses:  \(status.addresses.joined(separator: ", ").ifEmpty("none found")) (port \(status.port))",
            "  Home:       \(status.homeDirectory)",
            "  Devices:    \(status.pairedDevices) paired, \(status.connectedDevices) connected",
            "  Chats:      \(status.sessions) (\(status.activeSessions) working)",
            "  Bypass permissions allowed: \(status.bypassPermissionsAllowed ? "yes" : "no")",
            "  ntfy notifications: \(status.ntfy ? "on" : "off")",
            "  Agents:",
        ]
        for agent in status.agents {
            let state: String
            if !agent.installed {
                state = "not installed"
            } else {
                let signIn = agent.loggedIn.map { $0 ? "signed in" : "NOT signed in" } ?? "sign-in unknown"
                state = "\(agent.version ?? "installed") — \(signIn)\(agent.delegation ? ", delegation on" : "")"
            }
            lines.append("    \(agent.name): \(state)")
        }
        Console.log(lines.joined(separator: "\n"))
    }

    static func devices(_ options: ServerOptions) throws {
        let devices = try ControlClient(url: options.controlURL).request("GET", "/devices", as: [ControlDevice].self)
        guard !devices.isEmpty else {
            Console.log("No paired devices. Run `pilothouse-server pair`.")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for device in devices {
            let seen = device.lastSeenAt.map { formatter.string(from: Date(timeIntervalSince1970: $0)) } ?? "never"
            Console.log("\(device.id.prefix(10))  \(device.name) (\(device.platform))  \(device.connected ? "connected" : "last seen \(seen)")")
        }
    }

    static func revoke(_ id: String, options: ServerOptions) throws {
        let device = try ControlClient(url: options.controlURL).request("POST", "/revoke", body: id, as: ControlDevice.self)
        Console.log("Removed \(device.name). It has to be paired again to connect.")
    }

    /// An Avahi service file: copy it to `/etc/avahi/services/` on the host so
    /// phones find the host by Bonjour even after its address changed.
    static func avahiService(_ options: ServerOptions) throws {
        let status = try ControlClient(url: options.controlURL).request("GET", "/status", as: ControlStatus.self)
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        Console.log("""
            <?xml version="1.0" standalone='no'?>
            <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
            <service-group>
              <name>\(escaped(status.name))</name>
              <service>
                <type>\(PilothouseProtocol.bonjourServiceType)</type>
                <port>\(status.port)</port>
                <txt-record>id=\(status.fingerprint)</txt-record>
                <txt-record>v=\(status.protocolVersion)</txt-record>
              </service>
            </service-group>
            """)
    }
}

/// Renders a QR code for the terminal with `qrencode`, if it is installed.
enum QRCode {
    static func render(_ text: String) -> String? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
            .map { "\($0)/qrencode" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let path else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-t", "ANSIUTF8", "-m", "2", text]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
