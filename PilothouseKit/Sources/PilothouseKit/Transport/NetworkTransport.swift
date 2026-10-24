#if canImport(Network)
import Foundation
import Network
import Synchronization

extension NWParameters {
    /// TCP (keep-alive, no Nagle) + WebSocket, no TLS: confidentiality and
    /// authentication come from the Noise channel on top (SECURITY.md).
    static func pilothouseWebSocket() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = maximumMessageSize
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }
}

/// A WebSocket connection (client or server side) as a `MessageTransport`.
///
/// `@unchecked Sendable`: all stored properties are immutable references to
/// thread-safe Network.framework objects; callbacks run on `queue`.
public final class NWWebSocketTransport: PingableTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    public let peerDescription: String

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        peerDescription = "\(connection.endpoint)"
    }

    /// Opens a client connection and waits until the WebSocket upgrade completed.
    /// `localNetworkGrace` extends the wait while the Local Network alert may be
    /// on screen (see `start(timeout:localNetworkGrace:)`).
    public static func connect(
        to endpoint: Endpoint,
        timeout: Double,
        localNetworkGrace: Double = 0
    ) async throws -> NWWebSocketTransport {
        let nwEndpoint: NWEndpoint
        switch endpoint {
        case .hostPort(let host, let port):
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
                throw TransportError.connectionFailed("Invalid port \(port)")
            }
            nwEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        case .bonjour(let name, let type, let domain):
            nwEndpoint = .service(name: name, type: type, domain: domain, interface: nil)
        case .demo:
            throw TransportError.connectionFailed("The demo endpoint needs the demo connector")
        }
        let connection = NWConnection(to: nwEndpoint, using: .pilothouseWebSocket())
        let transport = NWWebSocketTransport(
            connection: connection,
            queue: DispatchQueue(label: "com.ardasenturk.Pilothouse.ws.client")
        )
        try await transport.start(timeout: timeout, localNetworkGrace: localNetworkGrace)
        return transport
    }

    /// Starts the connection and waits for `.ready`.
    ///
    /// `.waiting` is not a failure: Network.framework keeps retrying, and while
    /// iOS shows the Local Network alert the path is "denied" until the user
    /// answers (TN3179). Only a refused connection fails at once. When the
    /// deadline passes with the path denied for local-network reasons, the
    /// wait is extended by `localNetworkGrace`, then fails with
    /// `TransportError.localNetworkDenied` so the app can point to Settings.
    func start(timeout: Double, localNetworkGrace: Double = 0) async throws {
        let once = ResumeOnce<Void>()
        let connection = self.connection
        let queue = self.queue
        let denied = Mutex(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            once.install(continuation)
            @Sendable func fail(_ error: TransportError) {
                if once.resume(with: .failure(error)) {
                    connection.cancel()
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(with: .success(()))
                case .waiting(let error):
                    if case .localNetworkDenied? = connection.currentPath?.unsatisfiedReason {
                        denied.withLock { $0 = true }
                    } else if case .posix(.ECONNREFUSED) = error {
                        fail(.connectionFailed(error.localizedDescription))
                    }
                case .failed(let error):
                    fail(.connectionFailed(error.localizedDescription))
                case .cancelled:
                    once.resume(with: .failure(TransportError.closed))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            @Sendable func timedOut() -> TransportError {
                denied.withLock { $0 } ? .localNetworkDenied : .connectionFailed("Timed out after \(Int(timeout)) s")
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                guard denied.withLock({ $0 }), localNetworkGrace > 0 else { return fail(timedOut()) }
                queue.asyncAfter(deadline: .now() + localNetworkGrace) { fail(timedOut()) }
            }
        }
    }

    public func send(_ data: Data) async throws {
        guard data.count <= maximumMessageSize else { throw TransportError.messageTooLarge }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "pilothouse.binary", metadata: [metadata])
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: TransportError.connectionFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    public func receive() async throws -> Data {
        while true {
            let (data, opcode) = try await receiveFrame()
            switch opcode {
            case .binary:
                return data
            case .close:
                throw TransportError.closed
            default:
                // Text, ping, pong and continuation frames are not part of the protocol.
                continue
            }
        }
    }

    private func receiveFrame() async throws -> (Data, NWProtocolWebSocket.Opcode) {
        let connection = self.connection
        return try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { content, context, isComplete, error in
                if let error {
                    continuation.resume(throwing: TransportError.connectionFailed(error.localizedDescription))
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                if let metadata {
                    continuation.resume(returning: (content ?? Data(), metadata.opcode))
                } else if let content, !content.isEmpty {
                    continuation.resume(returning: (content, .binary))
                } else if isComplete {
                    continuation.resume(throwing: TransportError.closed)
                } else {
                    continuation.resume(returning: (Data(), .cont))
                }
            }
        }
    }

    public func ping(timeout: Double) async throws {
        let once = ResumeOnce<Void>()
        let connection = self.connection
        let queue = self.queue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            once.install(continuation)
            let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
            metadata.setPongHandler(queue) { error in
                if let error {
                    once.resume(with: .failure(TransportError.connectionFailed(error.localizedDescription)))
                } else {
                    once.resume(with: .success(()))
                }
            }
            let context = NWConnection.ContentContext(identifier: "pilothouse.ping", metadata: [metadata])
            connection.send(content: Data(), contentContext: context, isComplete: true, completion: .idempotent)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(with: .failure(TimeoutError()))
            }
        }
    }

    public func close() async {
        connection.cancel()
    }
}

/// Network.framework connector used by the iOS app.
public struct NetworkTransportConnector: TransportConnector {
    /// Extra seconds a LAN attempt waits while the Local Network alert may be
    /// up. Pairing (usually the app's first LAN access) passes a generous value.
    public var localNetworkGrace: Double

    public init(localNetworkGrace: Double = 0) {
        self.localNetworkGrace = localNetworkGrace
    }

    public func connect(to endpoint: Endpoint, timeout: Double) async throws -> any MessageTransport {
        try await NWWebSocketTransport.connect(to: endpoint, timeout: timeout, localNetworkGrace: localNetworkGrace)
    }
}

/// The Mac's WebSocket server: binds the first free port starting at the
/// preferred one and advertises itself over Bonjour.
public final class WebSocketListener: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var preferredPort: Int
        public var portSearchRange: Int
        public var bonjourName: String
        /// TXT record entries (`id` = Mac fingerprint, `v` = protocol version).
        public var txtRecord: [String: String]

        public init(
            preferredPort: Int = PilothouseProtocol.defaultPort,
            portSearchRange: Int = PilothouseProtocol.portSearchRange,
            bonjourName: String,
            txtRecord: [String: String]
        ) {
            self.preferredPort = preferredPort
            self.portSearchRange = portSearchRange
            self.bonjourName = bonjourName
            self.txtRecord = txtRecord
        }
    }

    private let queue = DispatchQueue(label: "com.ardasenturk.Pilothouse.ws.server")
    private let state = Mutex<NWListener?>(nil)
    private let log = PilothouseLog("WebSocketListener")

    public init() {}

    /// Binds and starts listening. Returns the bound port.
    public func start(
        configuration: Configuration,
        onConnection: @escaping @Sendable (any MessageTransport) -> Void
    ) async throws -> Int {
        var lastError: Error = TransportError.connectionFailed("No port available")
        let ports = configuration.preferredPort..<(configuration.preferredPort + configuration.portSearchRange)
        for port in ports {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { continue }
            do {
                let listener = try NWListener(using: .pilothouseWebSocket(), on: nwPort)
                listener.service = NWListener.Service(
                    name: configuration.bonjourName,
                    type: PilothouseProtocol.bonjourServiceType,
                    domain: nil,
                    txtRecord: NWTXTRecord(configuration.txtRecord)
                )
                let queue = self.queue
                listener.newConnectionHandler = { connection in
                    let transport = NWWebSocketTransport(connection: connection, queue: queue)
                    Task {
                        do {
                            try await transport.start(timeout: 10)
                            onConnection(transport)
                        } catch {
                            connection.cancel()
                        }
                    }
                }
                try await waitUntilReady(listener)
                state.withLock { $0 = listener }
                log.info("Listening on port \(port)")
                return port
            } catch {
                lastError = error
                log.info("Port \(port) unavailable: \(error)")
            }
        }
        throw lastError
    }

    private func waitUntilReady(_ listener: NWListener) async throws {
        let once = ResumeOnce<Void>()
        let log = self.log
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            once.install(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(with: .success(()))
                case .failed(let error), .waiting(let error):
                    if once.resume(with: .failure(TransportError.connectionFailed(error.localizedDescription))) {
                        listener.cancel()
                    } else {
                        log.error("Listener failed: \(error)")
                    }
                case .cancelled:
                    once.resume(with: .failure(TransportError.closed))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Updates the advertised Bonjour name / TXT record (e.g. Mac renamed).
    public func updateService(name: String, txtRecord: [String: String]) {
        state.withLock { listener in
            listener?.service = NWListener.Service(
                name: name,
                type: PilothouseProtocol.bonjourServiceType,
                domain: nil,
                txtRecord: NWTXTRecord(txtRecord)
            )
        }
    }

    public func stop() {
        state.withLock { listener in
            listener?.cancel()
            listener = nil
        }
    }
}

/// Browses `_pilothouse._tcp` and remembers which Mac (by TXT `id`) is where.
public final class BonjourBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ardasenturk.Pilothouse.bonjour")
    private let browser = Mutex<NWBrowser?>(nil)
    private let results = Mutex<[(endpoint: Endpoint, macId: String?)]>([])

    public init() {}

    public func start() {
        let alreadyRunning = browser.withLock { $0 != nil }
        guard !alreadyRunning else { return }
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: PilothouseProtocol.bonjourServiceType, domain: nil)
        let newBrowser = NWBrowser(for: descriptor, using: .tcp)
        newBrowser.browseResultsChangedHandler = { [weak self] found, _ in
            let mapped: [(endpoint: Endpoint, macId: String?)] = found.compactMap { result in
                guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
                var macId: String?
                if case .bonjour(let txt) = result.metadata {
                    macId = txt["id"]
                }
                return (Endpoint.bonjour(name: name, type: type, domain: domain), macId)
            }
            self?.results.withLock { $0 = mapped }
        }
        newBrowser.start(queue: queue)
        browser.withLock { $0 = newBrowser }
    }

    public func stop() {
        browser.withLock { current in
            current?.cancel()
            current = nil
        }
        results.withLock { $0 = [] }
    }

    /// Endpoints advertising `macId` (or every endpoint when `macId` is nil).
    public func endpoints(matching macId: String?) -> [Endpoint] {
        results.withLock { entries in
            entries.filter { macId == nil || $0.macId == macId }.map(\.endpoint)
        }
    }
}
#endif
