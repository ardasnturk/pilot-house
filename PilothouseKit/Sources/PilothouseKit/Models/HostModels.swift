import Foundation

/// An entry in a directory listing on the Mac.
public struct FileNode: Sendable, Hashable, Codable, Identifiable {
    public var id: String { path }
    public var name: String
    /// Absolute path on the Mac.
    public var path: String
    public var isDirectory: Bool
    public var isHidden: Bool
    public var isSymbolicLink: Bool
    /// The directory contains a `.git` entry.
    public var isGitRepository: Bool
    public var size: Int64?
    public var modifiedAt: Date?

    public init(
        name: String, path: String, isDirectory: Bool, isHidden: Bool = false, isSymbolicLink: Bool = false,
        isGitRepository: Bool = false, size: Int64? = nil, modifiedAt: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.isSymbolicLink = isSymbolicLink
        self.isGitRepository = isGitRepository
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

/// Result of `listDirectory`.
public struct DirectoryListing: Sendable, Hashable, Codable {
    /// Absolute, symlink-resolved path that was listed.
    public var path: String
    /// The user's home folder on the Mac (the browsing root).
    public var homePath: String
    /// Parent path, or `nil` at the home folder.
    public var parentPath: String?
    public var isGitRepository: Bool
    public var entries: [FileNode]
    /// `true` when the listing was cut at the entry limit.
    public var truncated: Bool

    public init(
        path: String, homePath: String, parentPath: String?, isGitRepository: Bool, entries: [FileNode],
        truncated: Bool = false
    ) {
        self.path = path
        self.homePath = homePath
        self.parentPath = parentPath
        self.isGitRepository = isGitRepository
        self.entries = entries
        self.truncated = truncated
    }

    /// Path relative to home, `~` based, for breadcrumbs.
    public var displayPath: String {
        guard path.hasPrefix(homePath) else { return path }
        let rest = path.dropFirst(homePath.count)
        return rest.isEmpty ? "~" : "~\(rest)"
    }
}

/// How a client reaches the Mac.
public enum ConnectionRoute: String, Sendable, Hashable, Codable {
    /// Same LAN (Bonjour or a private IP).
    case local
    /// Through Tailscale (100.64.0.0/10, fd7a:115c:a1e0::/48 or a `.ts.net` name).
    case tailscale
    /// In-process demo server.
    case demo
}

/// A network address the Mac can be reached at.
public struct HostAddress: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case local
        case tailscale
        case magicDNS
    }
    public var host: String
    public var kind: Kind

    public init(host: String, kind: Kind) {
        self.host = host
        self.kind = kind
    }

    public var route: ConnectionRoute {
        kind == .local ? .local : .tailscale
    }

    /// Classifies an address: Tailscale's CGNAT range, its ULA prefix and
    /// MagicDNS names count as Tailscale, everything else as local.
    public static func classify(_ host: String) -> Kind {
        let lower = host.lowercased()
        if lower.hasSuffix(".ts.net") || lower.hasSuffix(".ts.net.") { return .magicDNS }
        if lower.hasPrefix("fd7a:115c:a1e0:") { return .tailscale }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) { return .tailscale }
        return .local
    }
}

/// Tailscale state on the Mac.
public struct TailscaleStatus: Sendable, Hashable, Codable {
    public var installed: Bool
    /// `BackendState == "Running"`.
    public var running: Bool
    public var backendState: String?
    public var ipv4: String?
    public var ipv6: String?
    /// MagicDNS name without the trailing dot, e.g. `macbook.tail1234.ts.net`.
    public var magicDNSName: String?
    public var tailnetName: String?
    public var magicDNSEnabled: Bool

    public init(
        installed: Bool, running: Bool, backendState: String? = nil, ipv4: String? = nil, ipv6: String? = nil,
        magicDNSName: String? = nil, tailnetName: String? = nil, magicDNSEnabled: Bool = false
    ) {
        self.installed = installed
        self.running = running
        self.backendState = backendState
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.magicDNSName = magicDNSName
        self.tailnetName = tailnetName
        self.magicDNSEnabled = magicDNSEnabled
    }

    public static let notInstalled = TailscaleStatus(installed: false, running: false)

    /// Addresses to publish to paired devices (empty unless connected).
    public var addresses: [HostAddress] {
        guard running else { return [] }
        var result: [HostAddress] = []
        if let magicDNSName { result.append(HostAddress(host: magicDNSName, kind: .magicDNS)) }
        if let ipv4 { result.append(HostAddress(host: ipv4, kind: .tailscale)) }
        if let ipv6 { result.append(HostAddress(host: ipv6, kind: .tailscale)) }
        return result
    }
}

/// Claude CLI availability on the Mac.
public struct ClaudeCLIStatus: Sendable, Hashable, Codable {
    public var installed: Bool
    public var path: String?
    public var version: String?

    public init(installed: Bool, path: String? = nil, version: String? = nil) {
        self.installed = installed
        self.path = path
        self.version = version
    }
}

/// Response to `macStatus`.
public struct MacStatus: Sendable, Hashable, Codable {
    public var macName: String
    public var sleepPrevented: Bool
    public var lidClosedModeEnabled: Bool
    public var claude: ClaudeCLIStatus
    public var tailscale: TailscaleStatus
    public var addresses: [HostAddress]
    public var port: Int
    public var activeSessionCount: Int
    /// `bypassPermissions` may be offered to clients.
    public var bypassPermissionsAllowed: Bool
    public var defaultModel: String?

    public init(
        macName: String, sleepPrevented: Bool, lidClosedModeEnabled: Bool, claude: ClaudeCLIStatus,
        tailscale: TailscaleStatus, addresses: [HostAddress], port: Int, activeSessionCount: Int,
        bypassPermissionsAllowed: Bool, defaultModel: String? = nil
    ) {
        self.macName = macName
        self.sleepPrevented = sleepPrevented
        self.lidClosedModeEnabled = lidClosedModeEnabled
        self.claude = claude
        self.tailscale = tailscale
        self.addresses = addresses
        self.port = port
        self.activeSessionCount = activeSessionCount
        self.bypassPermissionsAllowed = bypassPermissionsAllowed
        self.defaultModel = defaultModel
    }
}

/// A phone or tablet paired with this Mac.
public struct PairedDevice: Sendable, Hashable, Codable, Identifiable {
    /// Fingerprint of `publicKey` (see `KeyFingerprint`).
    public var id: String
    public var name: String
    public var platform: String
    /// Raw 32-byte X25519 public key.
    public var publicKey: Data
    public var pairedAt: Date
    public var lastSeenAt: Date?

    public init(id: String, name: String, platform: String, publicKey: Data, pairedAt: Date, lastSeenAt: Date? = nil) {
        self.id = id
        self.name = name
        self.platform = platform
        self.publicKey = publicKey
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}

/// A Mac stored on the phone after pairing.
public struct PairedMac: Sendable, Hashable, Codable, Identifiable {
    /// Fingerprint of the Mac's public key.
    public var id: String
    public var name: String
    public var publicKey: Data
    public var addresses: [HostAddress]
    public var port: Int
    public var pairedAt: Date
    /// The last endpoint that worked; tried first.
    public var lastSuccessfulHost: String?
    public var lastSuccessfulPort: Int?
    /// The built-in demo Mac (demo mode).
    public var isDemo: Bool

    public init(
        id: String, name: String, publicKey: Data, addresses: [HostAddress], port: Int, pairedAt: Date,
        lastSuccessfulHost: String? = nil, lastSuccessfulPort: Int? = nil, isDemo: Bool = false
    ) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.addresses = addresses
        self.port = port
        self.pairedAt = pairedAt
        self.lastSuccessfulHost = lastSuccessfulHost
        self.lastSuccessfulPort = lastSuccessfulPort
        self.isDemo = isDemo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        publicKey = try container.decode(Data.self, forKey: .publicKey)
        addresses = try container.decode([HostAddress].self, forKey: .addresses)
        port = try container.decode(Int.self, forKey: .port)
        pairedAt = try container.decode(Date.self, forKey: .pairedAt)
        lastSuccessfulHost = try container.decodeIfPresent(String.self, forKey: .lastSuccessfulHost)
        lastSuccessfulPort = try container.decodeIfPresent(Int.self, forKey: .lastSuccessfulPort)
        isDemo = try container.decodeIfPresent(Bool.self, forKey: .isDemo) ?? false
    }
}
