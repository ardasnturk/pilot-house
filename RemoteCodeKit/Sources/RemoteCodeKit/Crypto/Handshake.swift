import Foundation

/// Payload of handshake message 1 (encrypted to the Mac's static key).
public struct ClientHandshakePayload: Sendable, Hashable, Codable {
    public enum Mode: String, Sendable, Hashable, Codable {
        /// First contact; `pairingToken` must be the one-time token from the QR code.
        case pair
        /// Reconnect of an already paired device.
        case connect
    }

    public var protocolVersion: Int
    public var mode: Mode
    public var pairingToken: String?
    public var deviceName: String
    public var platform: String
    public var appVersion: String
    public var timestamp: Date

    public init(
        protocolVersion: Int = RemoteCodeProtocol.version, mode: Mode, pairingToken: String? = nil, deviceName: String,
        platform: String, appVersion: String, timestamp: Date = Date()
    ) {
        self.protocolVersion = protocolVersion
        self.mode = mode
        self.pairingToken = pairingToken
        self.deviceName = deviceName
        self.platform = platform
        self.appVersion = appVersion
        self.timestamp = timestamp
    }
}

/// Payload of handshake message 2 (encrypted to the phone).
public struct ServerHandshakePayload: Sendable, Hashable, Codable {
    public var protocolVersion: Int
    public var accepted: Bool
    public var macName: String
    public var macId: String
    public var serverTime: Date
    public var error: ErrorPayload?

    public init(
        protocolVersion: Int = RemoteCodeProtocol.version, accepted: Bool, macName: String, macId: String,
        serverTime: Date = Date(), error: ErrorPayload? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.accepted = accepted
        self.macName = macName
        self.macId = macId
        self.serverTime = serverTime
        self.error = error
    }
}

/// What the Mac decides about an incoming handshake.
public enum HandshakeDecision: Sendable {
    case accept
    case reject(ErrorPayload)
}

/// A peer that completed the handshake on the Mac side.
public struct AuthenticatedPeer: Sendable {
    public let channel: SecureChannel
    public let publicKey: Data
    public let deviceId: String
    public let hello: ClientHandshakePayload
}

public enum HandshakeError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The Mac refused the connection and said why.
    case rejected(ErrorPayload)
    /// The peer's clock differs by more than `SecureHandshake.maximumClockSkew`.
    case clockSkew(seconds: Int)
    case protocolMismatch(remote: Int)
    case malformed
    case timedOut

    public var description: String {
        switch self {
        case .rejected(let error): error.message
        case .clockSkew(let seconds): "Clocks differ by \(seconds) seconds. Enable automatic date & time on both devices."
        case .protocolMismatch(let remote):
            "This app speaks protocol version \(RemoteCodeProtocol.version) but the other side speaks \(remote). Update both apps."
        case .malformed: "Invalid handshake message."
        case .timedOut: "The handshake timed out."
        }
    }
}

/// Mutually authenticated key agreement (`Noise_IK_25519_ChaChaPoly_SHA256`).
///
/// The phone (initiator) knows the Mac's static key from the QR code, so a
/// man-in-the-middle cannot impersonate the Mac; the Mac learns the phone's
/// static key in message 1 and authorises it (pairing token or pinned key).
/// See `docs/SECURITY.md`.
public enum SecureHandshake {
    /// Bound into the handshake hash; changing it makes old peers fail closed.
    static let prologue = Data("Pilothouse handshake v1".utf8)
    /// Maximum tolerated difference between the two clocks.
    public static let maximumClockSkew: TimeInterval = 300
    /// How long either side waits for the other's handshake message.
    public static let timeout: Double = 15

    /// Phone side: performs the handshake and returns the channel.
    public static func initiate(
        over transport: any MessageTransport,
        identity: IdentityKeyPair,
        macPublicKey: Data,
        payload: ClientHandshakePayload,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> (channel: SecureChannel, server: ServerHandshakePayload) {
        var initiator = try NoiseIKInitiator(
            staticPrivateKey: identity.rawPrivateKey,
            remoteStaticKey: macPublicKey,
            prologue: prologue
        )
        let message1 = try initiator.writeMessage1(payload: try RemoteCodeJSON.encode(payload))
        try await transport.send(Data([FrameType.handshakeInit.rawValue]) + message1)

        let frame: Data
        do {
            frame = try await withTimeout(seconds: timeout) { try await transport.receive() }
        } catch is TimeoutError {
            await transport.close()
            throw HandshakeError.timedOut
        }
        guard frame.first == FrameType.handshakeResponse.rawValue else {
            await transport.close()
            throw HandshakeError.malformed
        }
        let (responsePayload, keys) = try initiator.readMessage2(Data(frame.dropFirst()))
        let server: ServerHandshakePayload
        do {
            server = try RemoteCodeJSON.decode(ServerHandshakePayload.self, from: responsePayload)
        } catch {
            await transport.close()
            throw HandshakeError.malformed
        }
        guard server.accepted else {
            await transport.close()
            if let error = server.error {
                if error.code == .protocolMismatch { throw HandshakeError.protocolMismatch(remote: server.protocolVersion) }
                throw HandshakeError.rejected(error)
            }
            throw HandshakeError.rejected(ErrorPayload(code: .unauthorized, message: "The Mac refused the connection."))
        }
        let skew = server.serverTime.timeIntervalSince(now())
        guard abs(skew) <= maximumClockSkew else {
            await transport.close()
            throw HandshakeError.clockSkew(seconds: Int(skew))
        }
        return (SecureChannel(transport: transport, keys: keys), server)
    }

    /// Mac side: reads message 1, asks `authorize`, answers with message 2.
    ///
    /// Version and clock checks run before `authorize`. When the decision is a
    /// rejection the reason is sent (encrypted) to the phone and the transport is
    /// closed before this throws `HandshakeError.rejected`.
    public static func respond(
        over transport: any MessageTransport,
        identity: IdentityKeyPair,
        macName: String,
        now: @Sendable () -> Date = { Date() },
        authorize: @Sendable (_ publicKey: Data, _ hello: ClientHandshakePayload) async -> HandshakeDecision
    ) async throws -> AuthenticatedPeer {
        let frame: Data
        do {
            frame = try await withTimeout(seconds: timeout) { try await transport.receive() }
        } catch is TimeoutError {
            await transport.close()
            throw HandshakeError.timedOut
        }
        guard frame.first == FrameType.handshakeInit.rawValue else {
            await transport.close()
            throw HandshakeError.malformed
        }
        var responder = try NoiseIKResponder(staticPrivateKey: identity.rawPrivateKey, prologue: prologue)
        let remoteStatic: Data
        let helloData: Data
        do {
            (remoteStatic, helloData) = try responder.readMessage1(Data(frame.dropFirst()))
        } catch {
            // Wrong Mac key in the QR code, corrupted frame or an attacker: there is
            // no authenticated way to answer, so just hang up.
            await transport.close()
            throw HandshakeError.malformed
        }

        let macId = identity.fingerprint
        func finish(_ decision: HandshakeDecision, hello: ClientHandshakePayload?) async throws -> AuthenticatedPeer {
            let accepted: Bool
            let error: ErrorPayload?
            switch decision {
            case .accept:
                accepted = true
                error = nil
            case .reject(let payload):
                accepted = false
                error = payload
            }
            let payload = ServerHandshakePayload(accepted: accepted, macName: macName, macId: macId, serverTime: now(), error: error)
            let (message2, keys) = try responder.writeMessage2(payload: try RemoteCodeJSON.encode(payload))
            try await transport.send(Data([FrameType.handshakeResponse.rawValue]) + message2)
            guard accepted, let hello else {
                // Give the frame a moment to flush before tearing down the socket.
                try? await Task.sleep(for: .milliseconds(200))
                await transport.close()
                throw HandshakeError.rejected(error ?? ErrorPayload(code: .unauthorized, message: "Rejected"))
            }
            return AuthenticatedPeer(
                channel: SecureChannel(transport: transport, keys: keys),
                publicKey: remoteStatic,
                deviceId: KeyFingerprint.identifier(for: remoteStatic),
                hello: hello
            )
        }

        guard let hello = try? RemoteCodeJSON.decode(ClientHandshakePayload.self, from: helloData) else {
            return try await finish(
                .reject(ErrorPayload(code: .invalidRequest, message: "Invalid handshake payload.")),
                hello: nil
            )
        }
        guard hello.protocolVersion == RemoteCodeProtocol.version else {
            return try await finish(
                .reject(ErrorPayload(
                    code: .protocolMismatch,
                    message: "The Mac speaks protocol version \(RemoteCodeProtocol.version), this app speaks \(hello.protocolVersion). Update both apps."
                )),
                hello: nil
            )
        }
        let skew = hello.timestamp.timeIntervalSince(now())
        guard abs(skew) <= maximumClockSkew else {
            return try await finish(
                .reject(ErrorPayload(
                    code: .clockSkew,
                    message: "The clocks of your Mac and this device differ by \(abs(Int(skew))) seconds. Turn on automatic date & time on both."
                )),
                hello: nil
            )
        }
        return try await finish(await authorize(remoteStatic, hello), hello: hello)
    }
}
