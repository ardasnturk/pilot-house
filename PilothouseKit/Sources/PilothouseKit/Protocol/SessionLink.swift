import Foundation

/// Deep link that opens one session in the iOS app:
/// `pilothouse://session/<sessionId>?mac=<macId>`.
///
/// Used as the tap action of notifications (docs/DECISIONS.md D-095). `mac`
/// is optional; when present, the app switches to that paired Mac first.
public struct SessionLink: Sendable, Hashable {
    public static let host = "session"

    public var sessionId: String
    public var macId: String?

    public init(sessionId: String, macId: String? = nil) {
        self.sessionId = sessionId
        self.macId = macId
    }

    /// Parses a `pilothouse://session/<id>` link; `nil` for anything else.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == PairingPayload.scheme, url.host?.lowercased() == Self.host else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1, let id = components.first, Self.isValidSessionId(id) else { return nil }
        sessionId = id
        macId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "mac" })?.value
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = PairingPayload.scheme
        components.host = Self.host
        components.path = "/" + sessionId
        if let macId { components.queryItems = [URLQueryItem(name: "mac", value: macId)] }
        return components.url ?? URL(string: "\(PairingPayload.scheme)://\(Self.host)")!
    }

    /// Session IDs are lowercase UUIDs; accept any short token of safe characters.
    static func isValidSessionId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
