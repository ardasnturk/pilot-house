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
    public static func connect(to endpoint: Endpoint, timeout: Double) async throws -> NWWebSocketTransport {
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
        try await transport.start(timeout: timeout)
        return transport
    }

    /// Starts the connection and waits for `.ready`. `.waiting` counts as failure
    /// so the caller can move on to the next address quickly.
    func start(timeout: Double) async throws {
        let once = ResumeOnce<Void>()
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            once.install(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(with: .success(()))
                case .waiting(let error), .failed(let error):
                    if once.resume(with: .failure(TransportError.connectionFailed(error.localizedDescription))) {
                        connection.cancel()
                    }
                case .cancelled:
                    once.resume(with: .failure(TransportError.closed))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.resume(with: .failure(TransportError.connectionFailed("Timed out after \(Int(timeout)) s"))) {
                    connection.cancel()
                }
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
    public init() {}

    public func connect(to endpoint: Endpoint, timeout: Double) async throws -> any MessageTransport {
        try await NWWebSocketTransport.connect(to: endpoint, timeout: timeout)
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
        let results = self.results
        newBrowser.browseResultsChangedHandler = { found, _ in
            let mapped: [(endpoint: Endpoint, macId: String?)] = found.compactMap { result in
                guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
                var macId: String?
                if case .bonjour(let txt) = result.metadata {
                    macId = txt["id"]
                }
                return (Endpoint.bonjour(name: name, type: type, domain: domain), macId)
            }
            results.withLock { $0 = mapped }
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
