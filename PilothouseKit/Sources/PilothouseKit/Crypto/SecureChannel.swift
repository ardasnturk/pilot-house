import Foundation
import Synchronization

/// Frame types on the wire (first byte of every WebSocket binary message).
enum FrameType: UInt8 {
    /// Noise IK message 1 (phone → Mac).
    case handshakeInit = 0x01
    /// Noise IK message 2 (Mac → phone).
    case handshakeResponse = 0x02
    /// Encrypted application message: `0x03 ‖ counter(8, big-endian) ‖ ciphertext ‖ tag`.
    case transport = 0x03
}

public enum SecureChannelError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A frame arrived out of order or was replayed.
    case unexpectedCounter(expected: UInt64, received: UInt64)
    case malformedFrame
    case decryptionFailed
    case closed

    public var description: String {
        switch self {
        case .unexpectedCounter(let expected, let received):
            "Replayed or reordered frame (expected #\(expected), got #\(received))"
        case .malformedFrame: "Malformed encrypted frame"
        case .decryptionFailed: "Message authentication failed"
        case .closed: "Secure channel closed"
        }
    }
}

/// An authenticated, encrypted, replay-protected message channel over a
/// `MessageTransport`, created by `SecureHandshake`.
///
/// Every frame carries an explicit 64-bit counter that must be exactly the next
/// expected value; it doubles as the ChaCha20-Poly1305 nonce and is bound as
/// associated data, so replayed, dropped or reordered frames are rejected.
///
/// `send` is synchronous and thread-safe: frames are sealed and queued under a
/// lock, so they reach the socket in exactly the order `send` was called.
/// `receive` must only be called by one task at a time.
public final class SecureChannel: Sendable {
    /// The peer's authenticated static public key.
    public let remoteStaticKey: Data
    /// Noise handshake hash; unique per connection.
    public let handshakeHash: Data
    public let peerDescription: String

    private struct SendState {
        var cipher: NoiseCipherState
        var counter: UInt64 = 0
        var closed = false
    }

    private struct ReceiveState {
        var cipher: NoiseCipherState
        var counter: UInt64 = 0
    }

    private let transport: any MessageTransport
    private let sendState: Mutex<SendState>
    private let receiveState: Mutex<ReceiveState>
    private let outgoing: AsyncStream<Data>.Continuation
    private let writer: Task<Void, Never>

    init(transport: any MessageTransport, keys: NoiseTransportKeys) {
        self.transport = transport
        remoteStaticKey = keys.remoteStaticKey
        handshakeHash = keys.handshakeHash
        peerDescription = transport.peerDescription
        sendState = Mutex(SendState(cipher: keys.send))
        receiveState = Mutex(ReceiveState(cipher: keys.receive))
        let (frames, continuation) = AsyncStream.makeStream(of: Data.self)
        outgoing = continuation
        writer = Task {
            for await frame in frames {
                do {
                    try await transport.send(frame)
                } catch {
                    continuation.finish()
                    await transport.close()
                    return
                }
            }
        }
    }

    deinit {
        outgoing.finish()
    }

    /// Encrypts and queues `plaintext` for sending.
    public func send(_ plaintext: Data) throws {
        try sendState.withLock { state in
            guard !state.closed else { throw SecureChannelError.closed }
            var header = Data([FrameType.transport.rawValue])
            withUnsafeBytes(of: state.counter.bigEndian) { header.append(contentsOf: $0) }
            let ciphertext = try state.cipher.encrypt(associatedData: header, plaintext: plaintext)
            state.counter += 1
            if case .terminated = outgoing.yield(header + ciphertext) {
                state.closed = true
                throw SecureChannelError.closed
            }
        }
    }

    /// Waits for, authenticates and decrypts the next message.
    public func receive() async throws -> Data {
        let frame = try await transport.receive()
        guard frame.count >= 9 + Noise.tagLength, frame.first == FrameType.transport.rawValue else {
            throw SecureChannelError.malformedFrame
        }
        let bytes = Data(frame)
        let header = Data(bytes.prefix(9))
        let counter = header.dropFirst().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return try receiveState.withLock { state in
            guard counter == state.counter else {
                throw SecureChannelError.unexpectedCounter(expected: state.counter, received: counter)
            }
            do {
                let plaintext = try state.cipher.decrypt(associatedData: header, ciphertext: Data(bytes.dropFirst(9)))
                state.counter += 1
                return plaintext
            } catch {
                throw SecureChannelError.decryptionFailed
            }
        }
    }

    /// Flushes queued frames, then closes the transport. Idempotent.
    public func close() async {
        let alreadyClosed = sendState.withLock { state in
            defer { state.closed = true }
            return state.closed
        }
        outgoing.finish()
        if !alreadyClosed {
            await writer.value
        }
        await transport.close()
    }

    var underlyingTransport: any MessageTransport { transport }

    public var isClosed: Bool {
        sendState.withLock { $0.closed }
    }
}
