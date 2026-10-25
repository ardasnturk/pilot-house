import Foundation
import PilothouseHost
import PilothouseKit

/// Settings of the headless server. Each comes from a `PILOTHOUSE_*`
/// environment variable (Docker Compose's `environment:`); a few can be given
/// as flags too, which win. See `linux/README.md`.
struct ServerOptions: Sendable {
    var name: String
    var port: Int
    var portSearchRange: Int
    var homeDirectory: String
    var dataDirectory: URL
    /// LAN addresses to put into the pairing QR code; empty → detected.
    var advertisedAddresses: [String]
    /// Tailscale IPv4 address when the `tailscale` CLI is not reachable; empty → detected.
    var tailscaleAddress: String?
    var magicDNSName: String?
    var allowBypassPermissions: Bool
    var defaultModel: String?
    var defaultPermissionMode: PermissionMode
    var retentionDays: Int
    var delegationAgents: Set<AgentKind>
    /// Only when given explicitly; otherwise the CLI's own sign-in is used.
    var anthropicAPIKey: String?
    var ntfy: NtfyConfiguration?
    var notificationKinds: Set<HostAlert.Kind>
    var notificationIncludesDetail: Bool

    static let usage = """
        pilothouse-server — the Pilothouse host for Linux (Raspberry Pi, servers, Docker)

        Usage:
          pilothouse-server [serve] [--port N] [--name NAME] [--data-dir PATH]
                                  Run the host (the default command).
          pilothouse-server pair [--no-wait]
                                  Show a pairing QR code for the iPhone or iPad app.
          pilothouse-server status
                                  What the running host sees: addresses, agents, devices.
          pilothouse-server devices
                                  List paired devices.
          pilothouse-server revoke ID
                                  Remove a paired device (ID or its first characters).
          pilothouse-server avahi-service
                                  Print an Avahi service file so phones find the host by Bonjour.
          pilothouse-server version | help

        Settings come from PILOTHOUSE_* environment variables; see linux/README.md.
        """

    init(environment: [String: String], arguments: [String]) throws {
        func value(_ key: String) -> String? {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }
        func flag(_ key: String) -> Bool {
            guard let raw = value(key)?.lowercased() else { return false }
            return ["1", "true", "yes", "on"].contains(raw)
        }
        func list(_ key: String) -> [String] {
            (value(key) ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        }

        let home = value("PILOTHOUSE_HOME_DIR") ?? NSHomeDirectory()
        let dataHome = value("XDG_DATA_HOME") ?? "\(home)/.local/share"
        name = value("PILOTHOUSE_NAME") ?? Self.hostName()
        port = Int(value("PILOTHOUSE_PORT") ?? "") ?? PilothouseProtocol.defaultPort
        portSearchRange = value("PILOTHOUSE_PORT") == nil ? PilothouseProtocol.portSearchRange : 1
        homeDirectory = home
        dataDirectory = URL(fileURLWithPath: value("PILOTHOUSE_DATA_DIR") ?? "\(dataHome)/pilothouse", isDirectory: true)
        advertisedAddresses = list("PILOTHOUSE_ADDRESSES")
        tailscaleAddress = value("PILOTHOUSE_TAILSCALE_IP")
        magicDNSName = value("PILOTHOUSE_MAGICDNS_NAME")
        allowBypassPermissions = flag("PILOTHOUSE_ALLOW_BYPASS_PERMISSIONS")
        defaultModel = value("PILOTHOUSE_DEFAULT_MODEL")
        if let mode = value("PILOTHOUSE_DEFAULT_PERMISSION_MODE") {
            guard let parsed = PermissionMode(rawValue: mode) else {
                throw OptionError("PILOTHOUSE_DEFAULT_PERMISSION_MODE must be one of: \(PermissionMode.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            defaultPermissionMode = parsed
        } else {
            defaultPermissionMode = .default
        }
        retentionDays = Int(value("PILOTHOUSE_RETENTION_DAYS") ?? "") ?? 30
        delegationAgents = Set(list("PILOTHOUSE_DELEGATION_AGENTS").map { AgentKind($0.lowercased()) }.filter { $0 != .claude })
        // The CLIs never see ANTHROPIC_API_KEY unless API-key mode is chosen
        // (ClaudeCommand.environment); setting it for the server is that choice.
        anthropicAPIKey = value("PILOTHOUSE_ANTHROPIC_API_KEY") ?? value("ANTHROPIC_API_KEY")
        if let server = value("PILOTHOUSE_NTFY_SERVER"), let topic = value("PILOTHOUSE_NTFY_TOPIC") {
            guard let configuration = NtfyConfiguration(server: server, topic: topic, token: value("PILOTHOUSE_NTFY_TOKEN")) else {
                throw OptionError("PILOTHOUSE_NTFY_SERVER must be an http(s):// address and PILOTHOUSE_NTFY_TOPIC a valid topic.")
            }
            ntfy = configuration
        }
        let kinds = list("PILOTHOUSE_NOTIFY").compactMap { HostAlert.Kind(rawValue: $0) }
        notificationKinds = kinds.isEmpty ? Set(HostAlert.Kind.allCases) : Set(kinds)
        notificationIncludesDetail = flag("PILOTHOUSE_NOTIFY_DETAIL")

        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            func next() throws -> String {
                guard let value = remaining.popFirst() else { throw OptionError("\(argument) needs a value.") }
                return value
            }
            switch argument {
            case "--port":
                guard let parsed = Int(try next()), (1...65_535).contains(parsed) else { throw OptionError("--port needs a number.") }
                port = parsed
                portSearchRange = 1
            case "--name":
                name = try next()
            case "--data-dir":
                dataDirectory = URL(fileURLWithPath: try next(), isDirectory: true)
            default:
                throw OptionError("Unknown option \(argument).\n\n\(Self.usage)")
            }
        }
    }

    var identityURL: URL { dataDirectory.appendingPathComponent("identity.key") }
    var controlURL: URL { dataDirectory.appendingPathComponent("control.json") }

    func hostConfiguration(delegation: [AgentKind]) -> HostConfiguration {
        HostConfiguration(
            homeDirectory: homeDirectory,
            dataDirectory: dataDirectory,
            retentionDays: retentionDays,
            allowBypassPermissions: allowBypassPermissions,
            defaultModel: defaultModel,
            defaultPermissionMode: defaultPermissionMode,
            delegationAgents: delegation
        )
    }

    /// The machine's short host name (the Pi's, with Docker's host networking).
    static func hostName() -> String {
        let name = ProcessInfo.processInfo.hostName
        let short = name.split(separator: ".").first.map(String.init) ?? name
        return short.isEmpty || short == "localhost" ? "Raspberry Pi" : short
    }
}

struct OptionError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
