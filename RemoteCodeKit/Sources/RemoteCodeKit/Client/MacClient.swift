import Foundation

/// Describes the local device to the Mac.
public struct DeviceInfo: Sendable, Hashable {
    public var name: String
    public var platform: String
    public var appVersion: String

    public init(name: String, platform: String, appVersion: String) {
        self.name = name
        self.platform = platform
        self.appVersion = appVersion
    }
}

/// Connection state as shown in the UI.
public enum MacConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case connected(route: ConnectionRoute, endpoint: String)
    /// `localNetworkDenied`: a LAN attempt was refused by Local Network privacy.
    case waitingToRetry(until: Date, localNetworkDenied: Bool = false)
    /// Needs user action (re-pair, update the app, fix the clock).
    case failed(message: String, code: ErrorCode?)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

public enum MacClientError: Error, Sendable, Equatable, CustomStringConvertible {
    case notConnected
    case timedOut
    case unexpectedResponse(String)
    case unreachable([String])
    /// Only LAN addresses could have worked, and Local Network access is off.
    case localNetworkDenied

    public var description: String {
        switch self {
        case .notConnected: "Not connected to the Mac."
        case .timedOut: "The Mac did not answer in time."
        case .unexpectedResponse(let type): "Unexpected response \"\(type)\" from the Mac."
        case .unreachable(let attempts):
            "Could not reach the Mac (tried \(attempts.joined(separator: ", ")))."
        case .localNetworkDenied: "Local network access is not allowed."
        }
    }
}

/// Transports that can probe liveness (WebSocket ping/pong).
public protocol PingableTransport: MessageTransport {
    func ping(timeout: Double) async throws
}

/// Keeps an encrypted connection to one paired Mac: tries every known route,
/// re-connects with back-off, correlates requests with responses and exposes
/// server pushes as a stream.
public actor MacClient {
    /// Interval of liveness pings while connected.
    public static let heartbeatInterval: Double = 20

    public nonisolated let states: AsyncStream<MacConnectionState>
    /// Messages not answering a request: events, permission requests, updates,
    /// plus the `helloAck` of every new connection.
    public nonisolated let pushes: AsyncStream<ServerMessage>

    public private(set) var mac: PairedMac
    public private(set) var state: MacConnectionState = .idle

    private let identity: IdentityKeyPair
    private let device: DeviceInfo
    private let connector: any TransportConnector
    private let bonjourEndpoints: @Sendable () async -> [Endpoint]
    private let onMacUpdated: @Sendable (PairedMac) async -> Void
    private var preference: ConnectionPreference
    private let stateContinuation: AsyncStream<MacConnectionState>.Continuation
    private let pushContinuation: AsyncStream<ServerMessage>.Continuation
    private let log = RemoteCodeLog("MacClient")

    private var loopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var channel: SecureChannel?
    private var pending: [String: CheckedContinuation<ServerMessage, Error>] = [:]
    private var wake: CheckedContinuation<Void, Never>?
    private var sleepGeneration = 0

    public init(
        mac: PairedMac,
        identity: IdentityKeyPair,
        device: DeviceInfo,
        connector: any TransportConnector,
        preference: ConnectionPreference = .automatic,
        bonjourEndpoints: @escaping @Sendable () async -> [Endpoint] = { [] },
        onMacUpdated: @escaping @Sendable (PairedMac) async -> Void = { _ in }
    ) {
        self.mac = mac
        self.preference = preference
        self.identity = identity
        self.device = device
        self.connector = connector
        self.bonjourEndpoints = bonjourEndpoints
        self.onMacUpdated = onMacUpdated
        (states, stateContinuation) = AsyncStream.makeStream(of: MacConnectionState.self, bufferingPolicy: .bufferingNewest(16))
        (pushes, pushContinuation) = AsyncStream.makeStream(of: ServerMessage.self, bufferingPolicy: .unbounded)
    }

    // MARK: Lifecycle

    /// Starts connecting (no-op if already running).
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.connectionLoop()
        }
    }

    /// Disconnects and stops reconnecting.
    public func stop() async {
        loopTask?.cancel()
        loopTask = nil
        wakeUp()
        await dropConnection()
        setState(.idle)
    }

    /// Skips any pending back-off (call when the app becomes active or the
    /// network changes). Restarts after a fatal failure too.
    public func reconnectNow() {
        if case .failed = state {
            loopTask = nil
        }
        if loopTask == nil {
            start()
        } else {
            wakeUp()
        }
    }

    /// Changes the allowed routes and reconnects if needed.
    public func setPreference(_ preference: ConnectionPreference) {
        guard preference != self.preference else { return }
        self.preference = preference
        if case .connected(let route, _) = state,
            (preference == .localOnly && route == .tailscale) || (preference == .tailscaleOnly && route == .local)
        {
            let channel = self.channel
            Task { await channel?.close() }
        }
        wakeUp()
    }

    /// Replaces the stored addresses (e.g. after the Mac reported a new Tailscale IP).
    public func updateAddresses(_ addresses: [HostAddress], port: Int) {
        mac.addresses = addresses
        mac.port = port
    }

    // MARK: Requests

    /// Sends `message` and waits for the matching response. Server-side errors
    /// are thrown as `ErrorPayload`.
    public func request(_ message: ClientMessage, timeout: Double = 30) async throws -> ServerMessage {
        guard let channel else { throw MacClientError.notConnected }
        let envelope = ClientEnvelope(message: message)
        let data = try RemoteCodeJSON.encode(envelope)
        let id = envelope.id
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try channel.send(data)
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: MacClientError.notConnected)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expire(id)
            }
        }
    }

    private func expire(_ id: String) {
        pending.removeValue(forKey: id)?.resume(throwing: MacClientError.timedOut)
    }

    // MARK: Connection loop

    private func connectionLoop() async {
        var backoff = Backoff()
        while !Task.isCancelled {
            setState(.connecting)
            let candidates = ConnectionPlanner.candidates(for: mac, bonjour: await bonjourEndpoints(), preference: preference)
            var wasConnected = false
            var localNetworkDenied = false
            var attempts: [String] = []
            for candidate in candidates {
                if Task.isCancelled { return }
                do {
                    let (channel, ack) = try await establish(candidate)
                    wasConnected = true
                    backoff.reset()
                    await serve(channel: channel, ack: ack, candidate: candidate)
                    break
                } catch let error as HandshakeError {
                    if let fatal = Self.fatalFailure(error) {
                        setState(.failed(message: fatal.message, code: fatal.code))
                        loopTask = nil
                        return
                    }
                    attempts.append(candidate.endpoint.description)
                } catch let error as ErrorPayload where error.code == .protocolMismatch {
                    setState(.failed(message: error.message, code: error.code))
                    loopTask = nil
                    return
                } catch {
                    if error as? TransportError == .localNetworkDenied { localNetworkDenied = true }
                    attempts.append(candidate.endpoint.description)
                    log.debug("Attempt via \(candidate.endpoint) failed: \(error)")
                }
            }
            if Task.isCancelled { return }
            if wasConnected { continue }
            let delay = backoff.nextDelay()
            log.info("Mac unreachable via \(attempts); retrying in \(Int(delay))s")
            setState(.waitingToRetry(until: Date().addingTimeInterval(delay), localNetworkDenied: localNetworkDenied))
            await sleep(seconds: delay)
        }
    }

    private static func fatalFailure(_ error: HandshakeError) -> ErrorPayload? {
        switch error {
        case .rejected(let payload):
            switch payload.code {
            case .deviceRevoked, .unauthorized, .protocolMismatch, .clockSkew: return payload
            default: return nil
            }
        case .protocolMismatch, .clockSkew:
            return ErrorPayload(code: .protocolMismatch, message: error.description)
        case .malformed, .timedOut:
            return nil
        }
    }

    private func establish(_ candidate: ConnectionCandidate) async throws -> (SecureChannel, HelloAck) {
        let transport = try await connector.connect(to: candidate.endpoint, timeout: candidate.timeout)
        let (channel, _) = try await SecureHandshake.initiate(
            over: transport,
            identity: identity,
            macPublicKey: mac.publicKey,
            payload: ClientHandshakePayload(
                mode: .connect,
                deviceName: device.name,
                platform: device.platform,
                appVersion: device.appVersion
            )
        )
        do {
            let ack = try await Self.sayHello(over: channel, device: device)
            return (channel, ack)
        } catch {
            await channel.close()
            throw error
        }
    }

    /// Sends `hello` and waits for `helloAck` (the first message on a new channel).
    static func sayHello(over channel: SecureChannel, device: DeviceInfo) async throws -> HelloAck {
        let hello = ClientEnvelope(message: .hello(Hello(appVersion: device.appVersion, deviceName: device.name, platform: device.platform)))
        try channel.send(try RemoteCodeJSON.encode(hello))
        let data = try await withTimeout(seconds: 10) { try await channel.receive() }
        let response = try RemoteCodeJSON.decode(ServerEnvelope.self, from: data)
        switch response.message {
        case .helloAck(let ack): return ack
        case .error(let error): throw error
        default: throw MacClientError.unexpectedResponse(response.message.typeName)
        }
    }

    private func serve(channel: SecureChannel, ack: HelloAck, candidate: ConnectionCandidate) async {
        self.channel = channel
        if case .hostPort(let host, let port) = candidate.endpoint,
            mac.lastSuccessfulHost != host || mac.lastSuccessfulPort != port
        {
            mac.lastSuccessfulHost = host
            mac.lastSuccessfulPort = port
            await onMacUpdated(mac)
        }
        if ack.macName != mac.name {
            mac.name = ack.macName
            await onMacUpdated(mac)
        }
        setState(.connected(route: candidate.route, endpoint: candidate.endpoint.description))
        pushContinuation.yield(.helloAck(ack))
        startHeartbeat()

        while !Task.isCancelled {
            let data: Data
            do {
                data = try await channel.receive()
            } catch {
                log.info("Disconnected from \(mac.name): \(error)")
                break
            }
            dispatch(data)
        }
        await dropConnection()
    }

    private func dispatch(_ data: Data) {
        let envelope: ServerEnvelope
        do {
            envelope = try RemoteCodeJSON.decode(ServerEnvelope.self, from: data)
        } catch {
            log.error("Ignoring undecodable message: \(error)")
            return
        }
        if let re = envelope.re, let continuation = pending.removeValue(forKey: re) {
            if case .error(let error) = envelope.message {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: envelope.message)
            }
            return
        }
        if case .error(let error) = envelope.message, error.code == .deviceRevoked {
            setState(.failed(message: error.message, code: error.code))
            loopTask?.cancel()
            loopTask = nil
        }
        pushContinuation.yield(envelope.message)
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        guard let channel else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatInterval))
                if Task.isCancelled { return }
                guard let alive = await self?.ping(), !alive else { continue }
                await channel.close()
                return
            }
        }
    }

    /// Returns `false` if the transport did not answer a ping in time.
    private func ping() async -> Bool {
        guard let channel, let transport = channel.pingableTransport else { return true }
        do {
            try await transport.ping(timeout: 10)
            return true
        } catch {
            return false
        }
    }

    private func dropConnection() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        let channel = self.channel
        self.channel = nil
        for continuation in pending.values {
            continuation.resume(throwing: MacClientError.notConnected)
        }
        pending.removeAll()
        await channel?.close()
    }

    private func setState(_ newState: MacConnectionState) {
        guard newState != state else { return }
        state = newState
        stateContinuation.yield(newState)
    }

    private func sleep(seconds: Double) async {
        sleepGeneration += 1
        let generation = sleepGeneration
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wake = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                await self?.wakeUp(generation: generation)
            }
        }
    }

    /// Ends the current back-off sleep. A `generation` guards against a stale
    /// timer waking a later sleep.
    private func wakeUp(generation: Int? = nil) {
        if let generation, generation != sleepGeneration { return }
        wake?.resume()
        wake = nil
    }
}

extension SecureChannel {
    var pingableTransport: (any PingableTransport)? {
        underlyingTransport as? any PingableTransport
    }
}

// MARK: - Pairing

extension MacClient {
    /// Pairs with the Mac described by a scanned QR code and returns the
    /// record to store. Tries every address in the payload.
    public static func pair(
        payload: PairingPayload,
        identity: IdentityKeyPair,
        device: DeviceInfo,
        connector: any TransportConnector,
        now: Date = Date()
    ) async throws -> PairedMac {
        guard !payload.isExpired(at: now) else {
            throw ErrorPayload(code: .pairingTokenInvalid, message: "This pairing code has expired. Create a new one on your Mac.")
        }
        guard let publicKey = payload.publicKey, let macId = payload.macId else {
            throw PairingPayload.ParseError.invalidKey
        }
        var mac = PairedMac(
            id: macId,
            name: payload.name,
            publicKey: publicKey,
            addresses: payload.addresses,
            port: payload.port,
            pairedAt: now
        )
        var attempts: [String] = []
        var localNetworkDenied = false
        for candidate in ConnectionPlanner.candidates(for: mac, bonjour: []) {
            let transport: any MessageTransport
            do {
                transport = try await connector.connect(to: candidate.endpoint, timeout: candidate.timeout)
            } catch {
                if error as? TransportError == .localNetworkDenied { localNetworkDenied = true }
                attempts.append("\(candidate.endpoint): \(error)")
                continue
            }
            let channel: SecureChannel
            do {
                (channel, _) = try await SecureHandshake.initiate(
                    over: transport,
                    identity: identity,
                    macPublicKey: publicKey,
                    payload: ClientHandshakePayload(
                        mode: .pair,
                        pairingToken: payload.token,
                        deviceName: device.name,
                        platform: device.platform,
                        appVersion: device.appVersion
                    )
                )
            } catch HandshakeError.rejected(let reason) {
                throw reason
            } catch {
                attempts.append("\(candidate.endpoint): handshake \(error)")
                continue
            }
            let ack = try await sayHello(over: channel, device: device)
            await channel.close()
            mac.name = ack.macName
            if case .hostPort(let host, let port) = candidate.endpoint {
                mac.lastSuccessfulHost = host
                mac.lastSuccessfulPort = port
            }
            return mac
        }
        throw localNetworkDenied ? MacClientError.localNetworkDenied : MacClientError.unreachable(attempts)
    }
}
