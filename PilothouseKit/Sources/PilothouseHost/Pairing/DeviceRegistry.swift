import Foundation
import PilothouseKit

/// Issues one-time pairing tokens (prompt §5.2: 5 minutes, single use).
public actor PairingManager {
    private var tokens: [String: Date] = [:]

    public init() {}

    /// Creates a fresh token; earlier tokens stay valid until they expire.
    public func createToken(now: Date = Date()) -> (token: String, expiresAt: Date) {
        purge(now: now)
        let token = SessionManager.randomToken()
        let expiresAt = now.addingTimeInterval(PairingPayload.tokenLifetime)
        tokens[token] = expiresAt
        return (token, expiresAt)
    }

    /// Validates and consumes `candidate`. Comparison is constant-time per token.
    public func consume(_ candidate: String, now: Date = Date()) -> Bool {
        purge(now: now)
        var match: String?
        for token in tokens.keys where Self.constantTimeEquals(token, candidate) {
            match = token
        }
        guard let match else { return false }
        tokens.removeValue(forKey: match)
        return true
    }

    /// Invalidates every outstanding token (pairing window closed).
    public func revokeAll() {
        tokens.removeAll()
    }

    public var activeTokenCount: Int { tokens.count }

    private func purge(now: Date) {
        tokens = tokens.filter { $0.value > now }
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

/// Paired phones, persisted in `devices.json`; decides handshakes.
public actor DeviceRegistry: PeerAuthorizer {
    public nonisolated let url: URL
    private let pairing: PairingManager
    private let hub: NotificationHub
    private var devices: [String: PairedDevice] = [:]
    private var connected: [String: Int] = [:]
    private var observers: [UUID: AsyncStream<[PairedDevice]>.Continuation] = [:]

    public init(url: URL, pairing: PairingManager, hub: NotificationHub) {
        self.url = url
        self.pairing = pairing
        self.hub = hub
        if let data = try? Data(contentsOf: url), let decoded = try? PilothouseJSON.decode([PairedDevice].self, from: data) {
            devices = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    public var all: [PairedDevice] {
        devices.values.sorted { $0.pairedAt < $1.pairedAt }
    }

    public func isConnected(_ deviceId: String) -> Bool {
        (connected[deviceId] ?? 0) > 0
    }

    /// Emits the device list now and after every change (Mac UI).
    public func changes() -> AsyncStream<[PairedDevice]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [PairedDevice].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(all)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    // MARK: PeerAuthorizer

    public func authorize(publicKey: Data, hello: ClientHandshakePayload) async -> HandshakeDecision {
        let deviceId = KeyFingerprint.identifier(for: publicKey)
        switch hello.mode {
        case .pair:
            guard let token = hello.pairingToken, await pairing.consume(token) else {
                return .reject(ErrorPayload(
                    code: .pairingTokenInvalid,
                    message: "This pairing code is invalid, expired or was already used. Create a new one on your Mac."
                ))
            }
            let existing = devices[deviceId]
            devices[deviceId] = PairedDevice(
                id: deviceId,
                name: hello.deviceName,
                platform: hello.platform,
                publicKey: publicKey,
                pairedAt: existing?.pairedAt ?? Date(),
                lastSeenAt: Date()
            )
            save()
            return .accept
        case .connect:
            guard let device = devices[deviceId], device.publicKey == publicKey else {
                return .reject(ErrorPayload(
                    code: .unauthorized,
                    message: "This device is not paired with this Mac (or was removed). Scan a new pairing code."
                ))
            }
            return .accept
        }
    }

    public func peerConnected(deviceId: String, hello: ClientHandshakePayload) async {
        connected[deviceId, default: 0] += 1
        guard var device = devices[deviceId] else { return }
        device.lastSeenAt = Date()
        if device.name != hello.deviceName { device.name = hello.deviceName }
        devices[deviceId] = device
        save()
    }

    public func peerDisconnected(deviceId: String) async {
        connected[deviceId] = max(0, (connected[deviceId] ?? 1) - 1)
        if var device = devices[deviceId] {
            device.lastSeenAt = Date()
            devices[deviceId] = device
            save()
        }
    }

    /// Removes a device and drops its live connections immediately.
    public func revoke(_ deviceId: String) async {
        guard devices.removeValue(forKey: deviceId) != nil else { return }
        save()
        await hub.post(.disconnectDevice(
            deviceId: deviceId,
            reason: ErrorPayload(code: .deviceRevoked, message: "This device was removed on the Mac. Pair again to reconnect.")
        ))
    }

    private func save() {
        if let data = try? PilothouseJSON.encoder(pretty: true).encode(all) {
            try? PrivateFiles.writeAtomically(data, to: url)
        }
        let snapshot = all
        for observer in observers.values { observer.yield(snapshot) }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}
