import Foundation
import PilothouseKit
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The Linux host's WebSocket server (D-110): BSD sockets plus `WebSocketCodec`,
/// so it runs wherever the package builds. Binds the first free port from the
/// preferred one on every interface (IPv6 dual-stack, IPv4 as a fallback).
///
/// One thread accepts; each connection gets a thread that reads and decodes
/// frames. The owner must call `stop()`; the accept thread keeps it alive.
public final class POSIXWebSocketListener: Sendable {
    public let port: Int
    private let listenSocket: Int32
    private let onConnection: @Sendable (any MessageTransport) -> Void
    private let stopped = Mutex(false)
    private let log = PilothouseLog("POSIXWebSocketListener")

    struct SocketError: Error {
        var code: Int32
    }

    /// Seconds a new connection may take to send its upgrade request.
    static let handshakeTimeout = 10

    /// Binds and starts accepting immediately.
    public init(
        preferredPort: Int = PilothouseProtocol.defaultPort,
        portSearchRange: Int = PilothouseProtocol.portSearchRange,
        onConnection: @escaping @Sendable (any MessageTransport) -> Void
    ) throws {
        var lastError: Int32 = EADDRINUSE
        var bound: (fd: Int32, port: Int)?
        for candidate in preferredPort..<(preferredPort + max(portSearchRange, 1)) {
            switch Self.listeningSocket(port: candidate) {
            case .success(let fd):
                bound = (fd, candidate)
            case .failure(let error):
                lastError = error.code
                continue
            }
            break
        }
        guard let bound else { throw ChildProcessError.pipeFailed(errno: lastError) }
        listenSocket = bound.fd
        port = bound.port
        self.onConnection = onConnection
        log.info("Listening on port \(bound.port)")

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "pilothouse.ws.accept"
        thread.start()
    }

    deinit {
        stop()
    }

    /// Closes the listening socket. Open connections stay until closed by their owner.
    public func stop() {
        let wasStopped = stopped.withLock { value -> Bool in
            defer { value = true }
            return value
        }
        guard !wasStopped else { return }
        shutdown(listenSocket, Int32(SHUT_RDWR))
        close(listenSocket)
    }

    private var isStopped: Bool { stopped.withLock { $0 } }

    /// A listening socket on `port`: IPv6 dual-stack, or IPv4 when IPv6 is off.
    private static func listeningSocket(port: Int) -> Result<Int32, SocketError> {
        let dualStack = bindSocket(family: AF_INET6, port: port)
        if case .success = dualStack { return dualStack }
        if case .failure(let error) = dualStack, error.code == EADDRINUSE { return dualStack }
        return bindSocket(family: AF_INET, port: port)
    }

    private static func bindSocket(family: Int32, port: Int) -> Result<Int32, SocketError> {
        #if canImport(Darwin)
        let fd = socket(family, SOCK_STREAM, 0)
        #else
        let fd = socket(family, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return .failure(SocketError(code: errno)) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let result: Int32
        if family == AF_INET6 {
            var no: Int32 = 0
            setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            #if canImport(Darwin)
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = UInt16(port).bigEndian
            address.sin6_addr = in6addr_any
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = 0 // INADDR_ANY
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard result == 0, listen(fd, 32) == 0 else {
            let code = errno
            close(fd)
            return .failure(SocketError(code: code))
        }
        return .success(fd)
    }

    private func acceptLoop() {
        while !isStopped {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenSocket, $0, &length) }
            }
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            let peer = Self.describe(storage)
            let onConnection = self.onConnection
            let log = self.log
            let thread = Thread {
                POSIXWebSocketTransport.serve(fd: client, peer: peer, log: log, onConnection: onConnection)
            }
            thread.name = "pilothouse.ws.connection"
            thread.start()
        }
    }

    /// `address:port` of a peer, for logs.
    static func describe(_ storage: sockaddr_storage) -> String {
        var copy = storage
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let length = socklen_t(storage.ss_family == sa_family_t(AF_INET6) ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
        let status = withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), &service, socklen_t(service.count), NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard status == 0 else { return "unknown peer" }
        func text(_ chars: [CChar]) -> String {
            String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        var address = text(host)
        if address.hasPrefix("::ffff:") { address.removeFirst(7) }
        return address.contains(":") ? "[\(address)]:\(text(service))" : "\(address):\(text(service))"
    }
}

/// The server end of one phone connection (RFC 6455 over a TCP socket).
///
/// A dedicated thread reads the socket, answers pings and close frames and
/// hands complete binary messages to `receive()`. Writes run in order on a
/// serial queue. The socket is shut down by `close()` or when the peer goes
/// away, and closed when the transport is released, so a descriptor is never
/// reused while a write may still reach it.
public final class POSIXWebSocketTransport: MessageTransport {
    public let peerDescription: String
    private let fd: Int32
    private let inbox = MessageInbox()
    private let writer = DispatchQueue(label: "com.ardasenturk.Pilothouse.ws.write")
    private let isShutDown = Mutex(false)

    private init(fd: Int32, peerDescription: String) {
        self.fd = fd
        self.peerDescription = peerDescription
    }

    deinit {
        closeSocket(fd)
    }

    /// Runs on the connection thread: the upgrade, then frames until the end.
    static func serve(
        fd: Int32, peer: String, log: PilothouseLog, onConnection: @Sendable (any MessageTransport) -> Void
    ) {
        configure(fd)
        var buffer = Data()
        var timeout = timeval(tv_sec: POSIXWebSocketListener.handshakeTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let head: String
        while true {
            if let end = WebSocketCodec.endOfHead(in: buffer) {
                head = String(decoding: buffer[buffer.startIndex..<(end - 4)], as: UTF8.self)
                buffer = Data(buffer[end...])
                break
            }
            guard buffer.count < 16_384, let chunk = readChunk(fd) else {
                closeSocket(fd)
                return
            }
            buffer.append(chunk)
        }
        let response: Data
        do {
            response = try WebSocketCodec.handshakeResponse(forRequest: head)
        } catch {
            log.info("Rejected a non-WebSocket request from \(peer): \(error)")
            _ = writeAll(fd, WebSocketCodec.badRequestResponse)
            closeSocket(fd)
            return
        }
        guard writeAll(fd, response) else {
            closeSocket(fd)
            return
        }
        // From now on the read waits as long as the connection lives; dead peers
        // are found by TCP keep-alive and by the phone's own pings.
        timeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let transport = POSIXWebSocketTransport(fd: fd, peerDescription: peer)
        onConnection(transport)
        transport.readLoop(buffer: buffer)
    }

    /// TCP options matching the Mac's listener: no Nagle, keep-alive after 15 s.
    private static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var yes: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var idle: Int32 = 15
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size))
        #else
        var idle: Int32 = 15
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_KEEPIDLE, &idle, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var interval: Int32 = 5
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_KEEPINTVL, &interval, socklen_t(MemoryLayout<Int32>.size))
        var count: Int32 = 3
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_KEEPCNT, &count, socklen_t(MemoryLayout<Int32>.size))
        // A phone that stops reading must not block a writer forever.
        var sendTimeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func readLoop(buffer initial: Data) {
        var buffer = initial
        var fragments = Data()
        defer {
            shutDownSocket()
            inbox.finish()
        }
        while true {
            let frame: WebSocketCodec.Frame?
            do {
                frame = try WebSocketCodec.decodeClientFrame(&buffer)
            } catch {
                enqueueWrite(WebSocketCodec.encodeServerFrame(.close, payload: Data()))
                return
            }
            guard let frame else {
                guard let chunk = Self.readChunk(fd) else { return }
                buffer.append(chunk)
                continue
            }
            switch frame.opcode {
            case .binary, .continuation:
                fragments.append(frame.payload)
                guard fragments.count <= maximumMessageSize else { return }
                if frame.isFinal {
                    inbox.push(fragments)
                    fragments = Data()
                }
            case .ping:
                enqueueWrite(WebSocketCodec.encodeServerFrame(.pong, payload: frame.payload))
            case .pong, .text:
                continue // not part of the protocol
            case .close:
                enqueueWrite(WebSocketCodec.encodeServerFrame(.close, payload: Data()))
                writer.sync {}
                return
            }
        }
    }

    public func send(_ data: Data) async throws {
        guard data.count <= maximumMessageSize else { throw TransportError.messageTooLarge }
        let frame = WebSocketCodec.encodeServerFrame(.binary, payload: data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.async { [self] in
                if isShutDown.withLock({ $0 }) || !Self.writeAll(fd, frame) {
                    continuation.resume(throwing: TransportError.closed)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func receive() async throws -> Data {
        try await inbox.next()
    }

    public func close() async {
        guard !isShutDown.withLock({ $0 }) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.async { [self] in
                _ = Self.writeAll(fd, WebSocketCodec.encodeServerFrame(.close, payload: Data()))
                continuation.resume()
            }
        }
        shutDownSocket()
        inbox.finish()
    }

    private func enqueueWrite(_ frame: Data) {
        writer.async { [self] in
            guard !isShutDown.withLock({ $0 }) else { return }
            _ = Self.writeAll(fd, frame)
        }
    }

    private func shutDownSocket() {
        let alreadyShutDown = isShutDown.withLock { value -> Bool in
            defer { value = true }
            return value
        }
        if !alreadyShutDown { shutdown(fd, Int32(SHUT_RDWR)) }
    }

    /// Up to 64 KiB, or `nil` at the end of the stream or on an error.
    private static func readChunk(_ fd: Int32) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = bytes.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count > 0 { return Data(bytes[0..<count]) }
            if count < 0, errno == EINTR { continue }
            return nil
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                #if canImport(Darwin)
                let sent = Darwin.send(fd, pointer, remaining, 0)
                #else
                let sent = Glibc.send(fd, pointer, remaining, Int32(MSG_NOSIGNAL))
                #endif
                if sent < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= sent
                pointer = pointer.advanced(by: sent)
            }
            return true
        }
    }
}

/// `close(2)`; named apart because the transport's own `close()` shadows it.
private func closeSocket(_ fd: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(fd)
    #else
    _ = Glibc.close(fd)
    #endif
}

/// Complete messages from the reader thread, in order, for one `receive()` caller.
private final class MessageInbox: Sendable {
    private struct State {
        var messages: [Data] = []
        var waiter: CheckedContinuation<Data, Error>?
        var finished = false
    }

    private let state = Mutex(State())

    func push(_ message: Data) {
        let waiter = state.withLock { state -> CheckedContinuation<Data, Error>? in
            guard !state.finished else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.messages.append(message)
            return nil
        }
        waiter?.resume(returning: message)
    }

    func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<Data, Error>? in
            state.finished = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(throwing: TransportError.closed)
    }

    func next() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let result = state.withLock { state -> Result<Data, Error>? in
                if !state.messages.isEmpty { return .success(state.messages.removeFirst()) }
                if state.finished { return .failure(TransportError.closed) }
                state.waiter = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }
}
