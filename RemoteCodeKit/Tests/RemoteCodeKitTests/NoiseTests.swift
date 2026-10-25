import Foundation
import Testing
@testable import RemoteCodeKit

/// Verifies the Noise implementation against the cacophony test vector for
/// `Noise_IK_25519_ChaChaPoly_SHA256` (vectors/cacophony.txt, MIT/BSD licensed).
@Suite struct NoiseTests {
    struct Vector: Decodable {
        struct Message: Decodable {
            let payload: String
            let ciphertext: String
        }
        let protocol_name: String
        let init_prologue: String
        let init_static: String
        let init_ephemeral: String
        let init_remote_static: String
        let resp_static: String
        let resp_ephemeral: String
        let handshake_hash: String
        let messages: [Message]
    }

    func loadVector() throws -> Vector {
        let url = try #require(Bundle.module.url(forResource: "noise_ik_vector", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    func hex(_ string: String) throws -> Data {
        try #require(Data(hexString: string))
    }

    @Test func protocolNameMatchesVector() throws {
        #expect(try loadVector().protocol_name == Noise.protocolName)
    }

    @Test func handshakeAndTransportMatchCacophonyVector() throws {
        let vector = try loadVector()
        let prologue = try hex(vector.init_prologue)
        var initiator = try NoiseIKInitiator(
            staticPrivateKey: try hex(vector.init_static),
            remoteStaticKey: try hex(vector.init_remote_static),
            prologue: prologue,
            ephemeralPrivateKey: try hex(vector.init_ephemeral)
        )
        var responder = try NoiseIKResponder(
            staticPrivateKey: try hex(vector.resp_static),
            prologue: prologue,
            ephemeralPrivateKey: try hex(vector.resp_ephemeral)
        )

        // Message 1: initiator -> responder.
        let message1 = try initiator.writeMessage1(payload: try hex(vector.messages[0].payload))
        #expect(message1 == (try hex(vector.messages[0].ciphertext)))
        let (initiatorStatic, payload1) = try responder.readMessage1(message1)
        #expect(payload1 == (try hex(vector.messages[0].payload)))
        let expectedInitiatorStatic = try IdentityKeyPair(rawPrivateKey: try hex(vector.init_static)).publicKey
        #expect(initiatorStatic == expectedInitiatorStatic)

        // Message 2: responder -> initiator.
        let (message2, responderKeys) = try responder.writeMessage2(payload: try hex(vector.messages[1].payload))
        #expect(message2 == (try hex(vector.messages[1].ciphertext)))
        let (payload2, initiatorKeys) = try initiator.readMessage2(message2)
        #expect(payload2 == (try hex(vector.messages[1].payload)))
        #expect(initiatorKeys.handshakeHash == (try hex(vector.handshake_hash)))
        #expect(responderKeys.handshakeHash == initiatorKeys.handshakeHash)

        // Transport messages alternate initiator -> responder -> initiator ...
        var initiatorSend = initiatorKeys.send
        var initiatorReceive = initiatorKeys.receive
        var responderSend = responderKeys.send
        var responderReceive = responderKeys.receive
        for (index, message) in vector.messages.enumerated().dropFirst(2) {
            let payload = try hex(message.payload)
            let expected = try hex(message.ciphertext)
            if index % 2 == 0 {
                let ciphertext = try initiatorSend.encrypt(associatedData: Data(), plaintext: payload)
                #expect(ciphertext == expected, "transport message \(index)")
                #expect(try responderReceive.decrypt(associatedData: Data(), ciphertext: ciphertext) == payload)
            } else {
                let ciphertext = try responderSend.encrypt(associatedData: Data(), plaintext: payload)
                #expect(ciphertext == expected, "transport message \(index)")
                #expect(try initiatorReceive.decrypt(associatedData: Data(), ciphertext: ciphertext) == payload)
            }
        }
    }

    @Test func tamperedCiphertextIsRejected() throws {
        var cipher = NoiseCipherState(key: Data(repeating: 7, count: 32))
        var other = cipher
        var ciphertext = try cipher.encrypt(associatedData: Data([1]), plaintext: Data("hello".utf8))
        ciphertext[0] ^= 0xFF
        #expect(throws: NoiseError.decryptionFailed) {
            try other.decrypt(associatedData: Data([1]), ciphertext: ciphertext)
        }
    }

    @Test func wrongResponderKeyFailsHandshake() throws {
        let mac = IdentityKeyPair.generate()
        let impostor = IdentityKeyPair.generate()
        let phone = IdentityKeyPair.generate()
        var initiator = try NoiseIKInitiator(
            staticPrivateKey: phone.rawPrivateKey, remoteStaticKey: mac.publicKey, prologue: Data()
        )
        var responder = try NoiseIKResponder(staticPrivateKey: impostor.rawPrivateKey, prologue: Data())
        let message1 = try initiator.writeMessage1(payload: Data("hi".utf8))
        #expect(throws: NoiseError.decryptionFailed) {
            try responder.readMessage1(message1)
        }
    }
}
