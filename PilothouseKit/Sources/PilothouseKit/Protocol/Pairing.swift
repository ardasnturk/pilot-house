import Foundation

/// Contents of the pairing QR code:
/// `pilothouse://pair?d=<base64url(JSON)>`.
///
/// Keys are deliberately short to keep the QR code small and easy to scan.
public struct PairingPayload: Sendable, Hashable, Codable {
    public static let scheme = "pilothouse"
    public static let host = "pair"
    /// Validity of a pairing token (prompt §5.2: five minutes, single use).
    public static let tokenLifetime: TimeInterval = 5 * 60

    /// Payload format version.
    public var v: Int
    /// Mac name.
    public var name: String
    /// Mac static X25519 public key, base64url.
    public var pk: String
    /// Local IP addresses.
    public var lan: [String]
    /// Tailscale IP addresses.
    public var ts: [String]
    /// MagicDNS name, if any.
    public var dns: String?
    public var port: Int
    /// One-time pairing token, base64url.
    public var token: String
    /// Expiry as Unix seconds.
    public var exp: Int

    public init(
        name: String, publicKey: Data, localAddresses: [String], tailscaleAddresses: [String], magicDNSName: String?,
        port: Int, token: String, expiresAt: Date
    ) {
        v = 1
        self.name = name
        pk = Base64URL.encode(publicKey)
        lan = localAddresses
        ts = tailscaleAddresses
        dns = magicDNSName
        self.port = port
        self.token = token
        exp = Int(expiresAt.timeIntervalSince1970)
    }

    public var publicKey: Data? { Base64URL.decode(pk) }
    public var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(exp)) }
    public var macId: String? { publicKey.map(KeyFingerprint.identifier(for:)) }

    public func isExpired(at date: Date = Date()) -> Bool { date >= expiresAt }

    /// All addresses in connection-preference order (LAN, Tailscale IP, MagicDNS).
    public var addresses: [HostAddress] {
        lan.map { HostAddress(host: $0, kind: .local) }
            + ts.map { HostAddress(host: $0, kind: .tailscale) }
            + (dns.map { [HostAddress(host: $0, kind: .magicDNS)] } ?? [])
    }

    public var url: URL? {
        guard let json = try? JSONEncoder().encode(self) else { return nil }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [URLQueryItem(name: "d", value: Base64URL.encode(json))]
        return components.url
    }

    public enum ParseError: Error, Sendable, Equatable {
        case notAPairingLink
        case invalidPayload
        case unsupportedVersion(Int)
        case invalidKey
    }

    /// Parses a scanned or pasted pairing link. Surrounding whitespace is ignored.
    public init(link: String) throws {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == Self.scheme,
            components.host?.lowercased() == Self.host,
            let encoded = components.queryItems?.first(where: { $0.name == "d" })?.value
        else {
            throw ParseError.notAPairingLink
        }
        guard let json = Base64URL.decode(encoded) else { throw ParseError.invalidPayload }
        let decoded: PairingPayload
        do {
            decoded = try JSONDecoder().decode(PairingPayload.self, from: json)
        } catch {
            throw ParseError.invalidPayload
        }
        guard decoded.v == 1 else { throw ParseError.unsupportedVersion(decoded.v) }
        guard let key = decoded.publicKey, key.count == 32 else { throw ParseError.invalidKey }
        self = decoded
    }
}
