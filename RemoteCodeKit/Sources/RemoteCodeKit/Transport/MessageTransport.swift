import Foundation

/// Failure of the underlying message transport.
public enum TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case closed
    case connectionFailed(String)
    case unexpectedFrame
    case messageTooLarge
    /// iOS/macOS refused a LAN connection: the Local Network privilege is off
    /// (or its alert has not been answered yet).
    case localNetworkDenied

    public var description: String {
        switch self {
        case .closed: "The connection was closed."
        case .connectionFailed(let reason): "Connection failed: \(reason)"
        case .unexpectedFrame: "Received an unexpected frame."
        case .messageTooLarge: "Message too large."
        case .localNetworkDenied: "Local network access is not allowed."
        }
    }
}

/// A reliable, ordered, message-oriented byte transport (a WebSocket in production).
///
/// Implementations must deliver messages in order and support one concurrent
/// `receive()` caller plus any number of `send()` callers.
public protocol MessageTransport: Sendable {
    /// Sends one binary message.
    func send(_ data: Data) async throws
    /// Waits for the next binary message. Throws `TransportError.closed` once the
    /// peer has closed the connection.
    func receive() async throws -> Data
    /// Closes the connection. Idempotent.
    func close() async
    /// Human-readable peer description for logs (never contains secrets).
    var peerDescription: String { get }
}

/// Upper bound for a single protocol message (images are the largest).
public let maximumMessageSize = 16 * 1024 * 1024

/// A connected pair of in-memory transports, used by tests and the demo server.
public final class InMemoryTransport: MessageTransport {
    private let inbound: AsyncQueue<Data>
    private let outbound: AsyncQueue<Data>
    public let peerDescription: String

    private init(inbound: AsyncQueue<Data>, outbound: AsyncQueue<Data>, peerDescription: String) {
        self.inbound = inbound
        self.outbound = outbound
        self.peerDescription = peerDescription
    }

    /// Returns `(client, server)` ends of a fresh connection.
    public static func makePair() -> (client: InMemoryTransport, server: InMemoryTransport) {
        let toServer = AsyncQueue<Data>()
        let toClient = AsyncQueue<Data>()
        let client = InMemoryTransport(inbound: toClient, outbound: toServer, peerDescription: "in-memory server")
        let server = InMemoryTransport(inbound: toServer, outbound: toClient, peerDescription: "in-memory client")
        return (client, server)
    }

    public func send(_ data: Data) async throws {
        guard data.count <= maximumMessageSize else { throw TransportError.messageTooLarge }
        if await outbound.isFinished { throw TransportError.closed }
        await outbound.push(data)
    }

    public func receive() async throws -> Data {
        do {
            return try await inbound.pop()
        } catch is AsyncQueue<Data>.QueueClosedError {
            throw TransportError.closed
        }
    }

    public func close() async {
        await outbound.finish()
        await inbound.finish()
    }
}
