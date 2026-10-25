import Foundation
import Synchronization
import Testing
import PilothouseKit
@testable import PilothouseHost
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The Linux host's listener over real TCP sockets (D-110), driven by a phone-like
/// client that speaks `WebSocketCodec` like the iOS app's `TCPWebSocketTransport`.
@Suite(.serialized, .timeLimit(.minutes(1))) struct POSIXWebSocketListenerTests {
    static func makeListener(_ onConnection: @escaping @Sendable (any MessageTransport) -> Void) throws -> POSIXWebSocketListener {
        try POSIXWebSocketListener(preferredPort: Int.random(in: 40_000...50_000), portSearchRange: 50, onConnection: onConnection)
    }

    @Test func echoesMessagesBothWays() async throws {
        let listener = try Self.makeListener { transport in
            Task {
                while let message = try? await transport.receive() {
                    try? await transport.send(Data("echo:".utf8) + message)
                }
            }
        }
        defer { listener.stop() }
        let client = try await PhoneSocketTransport.connect(host: "127.0.0.1", port: listener.port)
        for size in [1, 200, 70_000, 1_000_000] {
            let message = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            try await client.send(message)
            #expect(try await client.receive() == Data("echo:".utf8) + message, "size \(size)")
        }
        await client.close()
    }

    @Test func answersPingsAndReportsTheClose() async throws {
        let received = Mutex<(any MessageTransport)?>(nil)
        let closed = AsyncQueue<Bool>()
        let listener = try Self.makeListener { transport in
            received.withLock { $0 = transport }
            Task {
                do {
                    _ = try await transport.receive()
                } catch {
                    await closed.push(error as? TransportError == .closed)
                }
            }
        }
        defer { listener.stop() }
        let client = try await PhoneSocketTransport.connect(host: "127.0.0.1", port: listener.port)
        try await client.ping(timeout: 5)
        #expect(received.withLock { $0 }?.peerDescription.hasPrefix("127.0.0.1:") == true)
        await client.close()
        #expect(try await withTimeout(seconds: 5) { try await closed.pop() })
    }

    @Test func rejectsPlainHTTP() async throws {
        let listener = try Self.makeListener { _ in Issue.record("Not a WebSocket connection") }
        defer { listener.stop() }
        let socket = try PhoneSocketTransport.openSocket(host: "127.0.0.1", port: listener.port)
        defer { close(socket) }
        _ = PhoneSocketTransport.write(socket, Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        let answer = String(decoding: PhoneSocketTransport.readChunk(socket) ?? Data(), as: UTF8.self)
        #expect(answer.hasPrefix("HTTP/1.1 400"))
    }

    @Test func usesTheNextPortWhenThePreferredOneIsTaken() throws {
        let first = try Self.makeListener { _ in }
        defer { first.stop() }
        let second = try POSIXWebSocketListener(preferredPort: first.port, portSearchRange: 5) { _ in }
        defer { second.stop() }
        #expect(second.port > first.port)
        #expect(throws: (any Error).self) { try POSIXWebSocketListener(preferredPort: first.port, portSearchRange: 1) { _ in } }
    }

    /// Pairing, the encrypted channel and a whole turn with FakeClaude: what
    /// the phone does against a Raspberry Pi.
    @Test func phonePairsAndRunsATurnOverTCP() async throws {
        let harness = try await SessionManagerTests.Harness()
        defer { Task { await harness.tearDown() } }
        let runtime = harness.runtime
        let listener = try Self.makeListener { transport in
            Task { await runtime.endpoint.accept(transport) }
        }
        defer { listener.stop() }

        let payload = await runtime.makePairingPayload(
            macName: "raspberrypi", localAddresses: ["127.0.0.1"], tailscale: .notInstalled, port: listener.port
        )
        let parsed = try PairingPayload(link: try #require(payload.url?.absoluteString))
        let phone = IdentityKeyPair.generate()
        let device = DeviceInfo(name: "Test iPhone", platform: "iOS", appVersion: "1.1.2")
        let mac = try await MacClient.pair(payload: parsed, identity: phone, device: device, connector: PhoneSocketConnector())
        #expect(mac.name == "Test Mac", "the name from the handshake wins")
        #expect(await runtime.devices.all.map(\.name) == ["Test iPhone"])

        let client = MacClient(mac: mac, identity: phone, device: device, connector: PhoneSocketConnector())
        await client.start()
        for await state in client.states where state.isConnected { break }
        let pushes = client.pushes
        guard case .sessionStarted(let started) = try await client.request(.startSession(StartSession(cwd: "~/project"))) else {
            Issue.record("Expected sessionStarted")
            return
        }
        let sessionId = started.session.id
        _ = try await client.request(.subscribe(Subscribe(sessionId: sessionId, fromSeq: 1)))
        _ = try await client.request(.sendMessage(SendMessage(sessionId: sessionId, text: "Hello from the phone")))
        var text = ""
        var result: SessionEvent.TurnResult?
        for await message in pushes {
            guard case .event(let event) = message, event.sessionId == sessionId else { continue }
            switch event.payload {
            case .assistantMessage(let message): text += message.text
            case .result(let turn): result = turn
            default: break
            }
            if result != nil { break }
        }
        #expect(text.contains("Hello from FakeClaude"))
        #expect(result?.isError == false)
        await client.stop()
    }
}

/// Pairs with a **running** `pilothouse-server` (e.g. the Docker image) like the
/// iPhone app does, then browses its home folder. Opt-in:
///
///     PILOTHOUSE_LIVE_PAIR_LINK="$(docker exec pilothouse pilothouse-server pair --no-wait | sed -n 's/^Link: *//p')" \
///       swift test --filter LiveLinuxServerTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PILOTHOUSE_LIVE_PAIR_LINK"] != nil), .timeLimit(.minutes(1)))
struct LiveLinuxServerTests {
    @Test func pairsAndBrowsesTheHomeFolder() async throws {
        let link = try #require(ProcessInfo.processInfo.environment["PILOTHOUSE_LIVE_PAIR_LINK"])
        let payload = try PairingPayload(link: link)
        let phone = IdentityKeyPair.generate()
        let device = DeviceInfo(name: "Live Test iPhone", platform: "iOS", appVersion: "1.1.2")
        let mac = try await MacClient.pair(payload: payload, identity: phone, device: device, connector: PhoneSocketConnector())
        print("Paired with \(mac.name) at \(mac.addresses.map(\.host))")

        let client = MacClient(mac: mac, identity: phone, device: device, connector: PhoneSocketConnector())
        await client.start()
        for await state in client.states where state.isConnected { break }
        guard case .macStatus(let status) = try await client.request(.macStatus) else {
            Issue.record("Expected macStatus")
            return
        }
        print("Claude: \(status.claude), agents: \(status.agents?.map(\.kind.rawValue) ?? [])")
        #expect(status.claude.installed)
        guard case .directoryListing(let home) = try await client.request(.listDirectory(ListDirectory())) else {
            Issue.record("Expected a listing")
            return
        }
        print("Home \(home.path): \(home.entries.map(\.name))")
        #expect(home.entries.contains { $0.name == "projects" && $0.isDirectory })
        guard case .sessionStarted(let started) = try await client.request(.startSession(StartSession(cwd: "~/projects"))) else {
            Issue.record("Expected sessionStarted")
            return
        }
        #expect(started.session.cwd.hasSuffix("/projects"))
        _ = try await client.request(.deleteSession(SessionRef(sessionId: started.session.id)))
        await client.stop()
    }
}

/// Connects the phone's client code to the Linux listener.
struct PhoneSocketConnector: TransportConnector {
    func connect(to endpoint: Endpoint, timeout: Double) async throws -> any MessageTransport {
        guard case .hostPort(let host, let port) = endpoint else { throw TransportError.connectionFailed("\(endpoint)") }
        return try await PhoneSocketTransport.connect(host: host, port: port)
    }
}

/// The client side of RFC 6455 over a blocking IPv4 socket, framed exactly like
/// the iOS app's `TCPWebSocketTransport` (masked frames, `WebSocketCodec`).
/// A reader thread decodes server frames, so sends never wait for a receive.
final class PhoneSocketTransport: PingableTransport {
    private let fd: Int32
    let peerDescription: String
    private let messages = AsyncQueue<Data>()
    private let pongs = AsyncQueue<Bool>()
    private let writeLock = Mutex(())

    private init(fd: Int32, peerDescription: String) {
        self.fd = fd
        self.peerDescription = peerDescription
    }

    deinit {
        closeDescriptor(fd)
    }

    static func connect(host: String, port: Int) async throws -> PhoneSocketTransport {
        let fd = try openSocket(host: host, port: port)
        let rest: Data
        do {
            rest = try handshake(fd, host: host, port: port)
        } catch {
            closeDescriptor(fd)
            throw error
        }
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
        let transport = PhoneSocketTransport(fd: fd, peerDescription: "\(host):\(port)")
        let thread = Thread { transport.readLoop(rest) }
        thread.start()
        return transport
    }

    static func openSocket(host: String, port: Int) throws -> Int32 {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw TransportError.connectionFailed("socket") }
        #if canImport(Darwin)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard result == 0 else {
            closeDescriptor(fd)
            throw TransportError.connectionFailed("connect errno \(errno)")
        }
        return fd
    }

    private static func handshake(_ fd: Int32, host: String, port: Int) throws -> Data {
        let key = WebSocketCodec.makeKey()
        guard write(fd, WebSocketCodec.handshakeRequest(host: host, port: port, key: key)) else { throw TransportError.closed }
        var buffer = Data()
        while true {
            if let end = WebSocketCodec.endOfHead(in: buffer) {
                let head = String(decoding: buffer[buffer.startIndex..<(end - 4)], as: UTF8.self)
                try WebSocketCodec.validateResponse(head, key: key)
                return Data(buffer[end...])
            }
            guard let chunk = readChunk(fd) else { throw TransportError.closed }
            buffer.append(chunk)
        }
    }

    private func readLoop(_ initial: Data) {
        var buffer = initial
        defer { deliver { await self.messages.finish() } }
        while true {
            let decoded: WebSocketCodec.Frame?
            do {
                decoded = try WebSocketCodec.decode(&buffer)
            } catch {
                return
            }
            guard let frame = decoded else {
                guard let chunk = Self.readChunk(fd) else { return }
                buffer.append(chunk)
                continue
            }
            switch frame.opcode {
            case .binary: deliver { await self.messages.push(frame.payload) }
            case .pong: deliver { await self.pongs.push(true) }
            case .close: return
            default: continue
            }
        }
    }

    /// Runs `operation` and waits, so messages stay in order.
    private func deliver(_ operation: @escaping @Sendable () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task {
            await operation()
            done.signal()
        }
        done.wait()
    }

    func send(_ data: Data) async throws {
        let ok = writeLock.withLock { _ in Self.write(fd, WebSocketCodec.encode(.binary, payload: data)) }
        guard ok else { throw TransportError.closed }
    }

    func receive() async throws -> Data {
        do {
            return try await messages.pop()
        } catch is AsyncQueue<Data>.QueueClosedError {
            throw TransportError.closed
        }
    }

    func ping(timeout: Double) async throws {
        let ok = writeLock.withLock { _ in Self.write(fd, WebSocketCodec.encode(.ping, payload: Data("p".utf8))) }
        guard ok else { throw TransportError.closed }
        _ = try await withTimeout(seconds: timeout) { try await self.pongs.pop() }
    }

    func close() async {
        writeLock.withLock { _ in _ = Self.write(fd, WebSocketCodec.encode(.close, payload: Data())) }
        shutdown(fd, Int32(SHUT_RDWR))
    }

    static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                #if canImport(Darwin)
                let sent = Darwin.send(fd, pointer, remaining, 0)
                #else
                let sent = Glibc.send(fd, pointer, remaining, Int32(MSG_NOSIGNAL))
                #endif
                if sent <= 0 { return false }
                remaining -= sent
                pointer = pointer.advanced(by: sent)
            }
            return true
        }
    }

    static func readChunk(_ fd: Int32) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let count = bytes.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        return count > 0 ? Data(bytes[0..<count]) : nil
    }
}

private func closeDescriptor(_ fd: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(fd)
    #else
    _ = Glibc.close(fd)
    #endif
}
