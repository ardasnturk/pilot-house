import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RemoteCodeKit

/// Where ntfy messages go (https://ntfy.sh or a self-hosted server).
public struct NtfyConfiguration: Sendable, Hashable {
    public static let defaultServer = "https://ntfy.sh"
    /// The ntfy iOS app on the App Store.
    public static let iOSAppURL = URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!
    static let topicAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    /// Base URL of the server, e.g. `https://ntfy.sh`.
    public var server: URL
    public var topic: String
    /// Optional access token (`tk_…`), sent as `Authorization: Bearer`.
    public var token: String?

    public init(server: URL, topic: String, token: String? = nil) {
        self.server = server
        self.topic = topic
        self.token = token.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `nil` unless `server` is an http(s) URL with a host and `topic` is valid.
    public init?(server: String, topic: String, token: String? = nil) {
        var text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false, Self.isValidTopic(topic)
        else { return nil }
        self.init(server: url, topic: topic, token: token)
    }

    /// A random 32-character topic. Anyone who knows the topic can read its
    /// messages on a public server, so it acts as a password.
    public static func randomTopic() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<32).map { _ in topicAlphabet.randomElement(using: &generator)! })
    }

    /// ntfy topics: 1–64 characters of letters, digits, `-` and `_`.
    public static func isValidTopic(_ topic: String) -> Bool {
        !topic.isEmpty && topic.count <= 64
            && topic.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// `https://ntfy.sh/<topic>`: what users subscribe to. The ntfy iOS app
    /// has no URL scheme (`ntfy://` links are Android-only), so the QR code
    /// carries this web address.
    public var topicURL: URL {
        server.appendingPathComponent(topic)
    }
}

/// One ntfy message, published as JSON (https://docs.ntfy.sh/publish/#publish-as-json).
public struct NtfyMessage: Sendable, Hashable, Encodable {
    public var topic: String
    public var title: String?
    public var message: String
    /// 1 (min) … 5 (max); 3 is the default.
    public var priority: Int?
    public var tags: [String]?
    /// Opened when the notification is tapped.
    public var click: String?

    public init(topic: String, title: String? = nil, message: String, priority: Int? = nil, tags: [String]? = nil, click: String? = nil) {
        self.topic = topic
        self.title = title
        self.message = message
        self.priority = priority
        self.tags = tags
        self.click = click
    }
}

public struct NtfyError: Error, Sendable, Hashable, CustomStringConvertible {
    public var statusCode: Int
    public var body: String

    public var description: String {
        body.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode): \(body)"
    }
}

/// Publishes alerts to an ntfy topic with a plain HTTPS POST.
public struct NtfyPublisher: AlertSink {
    public typealias Formatter = @Sendable (_ alert: HostAlert, _ includeDetail: Bool) -> AlertContent

    public let configuration: NtfyConfiguration
    /// Added to the tap link so the phone opens the session on the right Mac.
    public let macId: String?
    private let session: URLSession
    private let format: Formatter

    public init(
        configuration: NtfyConfiguration, macId: String? = nil, session: URLSession = .shared,
        format: @escaping Formatter = { AlertContent.english(for: $0, includeDetail: $1) }
    ) {
        self.configuration = configuration
        self.macId = macId
        self.session = session
        self.format = format
    }

    public func deliver(_ alert: HostAlert, includeDetail: Bool) async throws {
        try await publish(message(for: alert, includeDetail: includeDetail))
    }

    func message(for alert: HostAlert, includeDetail: Bool) -> NtfyMessage {
        let content = format(alert, includeDetail)
        let (priority, tag): (Int, String) = switch alert.kind {
        case .turnFinished: (3, "white_check_mark")
        case .permissionRequested: (4, "raised_hand")
        case .sessionFailed: (4, "x")
        case .subagentFinished: (2, "robot")
        }
        return NtfyMessage(
            topic: configuration.topic,
            title: content.title,
            message: content.body,
            priority: priority,
            tags: [tag],
            click: SessionLink(sessionId: alert.sessionId, macId: macId).url.absoluteString
        )
    }

    /// Sends `message` and returns the HTTP status (always 2xx; throws otherwise).
    @discardableResult
    public func publish(_ message: NtfyMessage) async throws -> Int {
        var request = URLRequest(url: configuration.server, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = configuration.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        var outgoing = message
        outgoing.topic = configuration.topic
        request.httpBody = try JSONEncoder().encode(outgoing)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NtfyError(statusCode: status, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return status
    }
}
