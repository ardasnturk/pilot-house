import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Errors from the Noise handshake and transport ciphers.
public enum NoiseError: Error, Sendable, Equatable {
    case invalidMessageLength
    case invalidPublicKey
    case decryptionFailed
    case nonceExhausted
    case handshakeOrder
}

/// Implementation of the parts of the Noise Protocol Framework (rev. 34) needed
/// for `Noise_IK_25519_ChaChaPoly_SHA256`, built on CryptoKit primitives.
///
/// Checked against the cacophony test vectors (see `NoiseTests`).
enum Noise {
    static let protocolName = "Noise_IK_25519_ChaChaPoly_SHA256"
    static let dhLength = 32
    static let tagLength = 16

    /// `DH(private, public)` over Curve25519.
    static func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKey: Data) throws -> Data {
        let remote: Curve25519.KeyAgreement.PublicKey
        do {
            remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw NoiseError.invalidPublicKey
        }
        do {
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: remote)
            return shared.withUnsafeBytes { Data($0) }
        } catch {
            // CryptoKit rejects low-order points (all-zero shared secret).
            throw NoiseError.invalidPublicKey
        }
    }

    /// Noise `HKDF(ck, ikm)` with two outputs (§4.3), HMAC-SHA256 based.
    static func hkdf2(chainingKey: Data, inputKeyMaterial: Data) -> (Data, Data) {
        let tempKey = SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: inputKeyMaterial, using: SymmetricKey(data: chainingKey)))
        let output1 = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: tempKey))
        let output2 = Data(HMAC<SHA256>.authenticationCode(for: output1 + Data([0x02]), using: tempKey))
        return (output1, output2)
    }

    static func hash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

/// Noise `CipherState` (§5.1): a ChaCha20-Poly1305 key plus a 64-bit nonce counter.
struct NoiseCipherState: Sendable {
    private(set) var key: Data?
    private(set) var nonce: UInt64 = 0

    init(key: Data? = nil) {
        self.key = key
    }

    var hasKey: Bool { key != nil }

    /// 96-bit ChaChaPoly nonce: 32 zero bits followed by the little-endian counter.
    static func nonceBytes(_ counter: UInt64) -> Data {
        var data = Data(count: 4)
        withUnsafeBytes(of: counter.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    mutating func encrypt(associatedData: Data, plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        guard nonce < UInt64.max else { throw NoiseError.nonceExhausted }
        let box = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: ChaChaPoly.Nonce(data: Self.nonceBytes(nonce)),
            authenticating: associatedData
        )
        nonce += 1
        // Re-base: CryptoKit returns slices whose indices do not start at 0.
        return Data(box.ciphertext) + Data(box.tag)
    }

    mutating func decrypt(associatedData: Data, ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard nonce < UInt64.max else { throw NoiseError.nonceExhausted }
        guard ciphertext.count >= Noise.tagLength else { throw NoiseError.invalidMessageLength }
        let body = ciphertext.prefix(ciphertext.count - Noise.tagLength)
        let tag = ciphertext.suffix(Noise.tagLength)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: Self.nonceBytes(nonce)),
                ciphertext: body,
                tag: tag
            )
            let plaintext = try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: associatedData)
            nonce += 1
            return plaintext
        } catch {
            throw NoiseError.decryptionFailed
        }
    }
}

/// Noise `SymmetricState` (§5.2).
struct NoiseSymmetricState: Sendable {
    private(set) var chainingKey: Data
    private(set) var handshakeHash: Data
    private(set) var cipher = NoiseCipherState()

    init(protocolName: String = Noise.protocolName) {
        let name = Data(protocolName.utf8)
        let initial = name.count <= 32 ? name + Data(count: 32 - name.count) : Noise.hash(name)
        chainingKey = initial
        handshakeHash = initial
    }

    mutating func mixKey(_ inputKeyMaterial: Data) {
        let (newChainingKey, key) = Noise.hkdf2(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial)
        chainingKey = newChainingKey
        cipher = NoiseCipherState(key: key)
    }

    mutating func mixHash(_ data: Data) {
        handshakeHash = Noise.hash(handshakeHash + data)
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(associatedData: handshakeHash, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(associatedData: handshakeHash, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    /// Returns `(initiator→responder, responder→initiator)` cipher states.
    func split() -> (NoiseCipherState, NoiseCipherState) {
        let (key1, key2) = Noise.hkdf2(chainingKey: chainingKey, inputKeyMaterial: Data())
        return (NoiseCipherState(key: key1), NoiseCipherState(key: key2))
    }
}

/// The result of a completed handshake.
struct NoiseTransportKeys: Sendable {
    var send: NoiseCipherState
    var receive: NoiseCipherState
    /// Final `h`; unique per session, usable for channel binding.
    var handshakeHash: Data
    /// The peer's static public key (authenticated by the handshake).
    var remoteStaticKey: Data
}

/// Initiator (phone) side of `IK`:
/// ```
/// <- s
/// ...
/// -> e, es, s, ss
/// <- e, ee, se
/// ```
struct NoiseIKInitiator: Sendable {
    private var symmetric = NoiseSymmetricState()
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private let ephemeralKey: Curve25519.KeyAgreement.PrivateKey
    private let remoteStaticKey: Data
    private var wroteFirstMessage = false

    init(
        staticPrivateKey: Data, remoteStaticKey: Data, prologue: Data, ephemeralPrivateKey: Data? = nil
    ) throws {
        staticKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivateKey)
        ephemeralKey = try ephemeralPrivateKey.map { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }
            ?? Curve25519.KeyAgreement.PrivateKey()
        guard remoteStaticKey.count == Noise.dhLength else { throw NoiseError.invalidPublicKey }
        self.remoteStaticKey = remoteStaticKey
        symmetric.mixHash(prologue)
        symmetric.mixHash(remoteStaticKey)
    }

    /// `-> e, es, s, ss` followed by the encrypted payload.
    mutating func writeMessage1(payload: Data) throws -> Data {
        guard !wroteFirstMessage else { throw NoiseError.handshakeOrder }
        wroteFirstMessage = true
        var message = Data()
        let ephemeralPublic = ephemeralKey.publicKey.rawRepresentation
        message.append(ephemeralPublic)
        symmetric.mixHash(ephemeralPublic)
        symmetric.mixKey(try Noise.dh(ephemeralKey, remoteStaticKey))
        message.append(try symmetric.encryptAndHash(staticKey.publicKey.rawRepresentation))
        symmetric.mixKey(try Noise.dh(staticKey, remoteStaticKey))
        message.append(try symmetric.encryptAndHash(payload))
        return message
    }

    /// `<- e, ee, se`, returns the decrypted payload and the transport keys.
    mutating func readMessage2(_ message: Data) throws -> (payload: Data, keys: NoiseTransportKeys) {
        guard wroteFirstMessage else { throw NoiseError.handshakeOrder }
        guard message.count >= Noise.dhLength + Noise.tagLength else { throw NoiseError.invalidMessageLength }
        let bytes = Data(message)
        let remoteEphemeral = bytes.prefix(Noise.dhLength)
        symmetric.mixHash(remoteEphemeral)
        symmetric.mixKey(try Noise.dh(ephemeralKey, remoteEphemeral))
        symmetric.mixKey(try Noise.dh(staticKey, remoteEphemeral))
        let payload = try symmetric.decryptAndHash(bytes.dropFirst(Noise.dhLength))
        let (initiatorToResponder, responderToInitiator) = symmetric.split()
        let keys = NoiseTransportKeys(
            send: initiatorToResponder,
            receive: responderToInitiator,
            handshakeHash: symmetric.handshakeHash,
            remoteStaticKey: remoteStaticKey
        )
        return (payload, keys)
    }
}

/// Responder (Mac) side of `IK`.
struct NoiseIKResponder: Sendable {
    private var symmetric = NoiseSymmetricState()
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private let ephemeralKey: Curve25519.KeyAgreement.PrivateKey
    private var remoteEphemeralKey: Data?
    private(set) var remoteStaticKey: Data?

    init(staticPrivateKey: Data, prologue: Data, ephemeralPrivateKey: Data? = nil) throws {
        staticKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivateKey)
        ephemeralKey = try ephemeralPrivateKey.map { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }
            ?? Curve25519.KeyAgreement.PrivateKey()
        symmetric.mixHash(prologue)
        symmetric.mixHash(staticKey.publicKey.rawRepresentation)
    }

    /// Reads `-> e, es, s, ss`. Returns the initiator's static key and payload.
    mutating func readMessage1(_ message: Data) throws -> (remoteStaticKey: Data, payload: Data) {
        guard remoteEphemeralKey == nil else { throw NoiseError.handshakeOrder }
        let encryptedStaticLength = Noise.dhLength + Noise.tagLength
        guard message.count >= Noise.dhLength + encryptedStaticLength + Noise.tagLength else {
            throw NoiseError.invalidMessageLength
        }
        let bytes = Data(message)
        let remoteEphemeral = bytes.prefix(Noise.dhLength)
        symmetric.mixHash(remoteEphemeral)
        symmetric.mixKey(try Noise.dh(staticKey, remoteEphemeral))
        let encryptedStatic = bytes.dropFirst(Noise.dhLength).prefix(encryptedStaticLength)
        let remoteStatic = try symmetric.decryptAndHash(Data(encryptedStatic))
        symmetric.mixKey(try Noise.dh(staticKey, remoteStatic))
        let payload = try symmetric.decryptAndHash(Data(bytes.dropFirst(Noise.dhLength + encryptedStaticLength)))
        remoteEphemeralKey = Data(remoteEphemeral)
        remoteStaticKey = remoteStatic
        return (remoteStatic, payload)
    }

    /// Writes `<- e, ee, se` with `payload`; returns the message and transport keys.
    mutating func writeMessage2(payload: Data) throws -> (message: Data, keys: NoiseTransportKeys) {
        guard let remoteEphemeralKey, let remoteStaticKey else { throw NoiseError.handshakeOrder }
        var message = Data()
        let ephemeralPublic = ephemeralKey.publicKey.rawRepresentation
        message.append(ephemeralPublic)
        symmetric.mixHash(ephemeralPublic)
        symmetric.mixKey(try Noise.dh(ephemeralKey, remoteEphemeralKey))
        symmetric.mixKey(try Noise.dh(ephemeralKey, remoteStaticKey))
        message.append(try symmetric.encryptAndHash(payload))
        let (initiatorToResponder, responderToInitiator) = symmetric.split()
        let keys = NoiseTransportKeys(
            send: responderToInitiator,
            receive: initiatorToResponder,
            handshakeHash: symmetric.handshakeHash,
            remoteStaticKey: remoteStaticKey
        )
        return (message, keys)
    }
}
