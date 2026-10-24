import Foundation
import Testing
@testable import PilothouseKit

@Suite struct PairingPayloadTests {
    func makePayload(expiresAt: Date = Date().addingTimeInterval(300)) -> PairingPayload {
        PairingPayload(
            name: "Arda's MacBook", publicKey: IdentityKeyPair.generate().publicKey,
            localAddresses: ["192.168.1.20", "10.0.0.4"], tailscaleAddresses: ["100.100.1.2"],
            magicDNSName: "macbook.tail1.ts.net", port: 47823, token: "tok", expiresAt: expiresAt
        )
    }

    @Test func urlRoundTrip() throws {
        let payload = makePayload()
        let url = try #require(payload.url)
        #expect(url.scheme == "pilothouse")
        #expect(url.host == "pair")
        #expect(try PairingPayload(link: "  \(url.absoluteString)\n") == payload)
    }

    @Test func addressesAreInPreferenceOrder() {
        let addresses = makePayload().addresses
        #expect(addresses.map(\.kind) == [.local, .local, .tailscale, .magicDNS])
    }

    @Test func expiry() {
        let payload = makePayload(expiresAt: Date(timeIntervalSince1970: 1_000))
        #expect(payload.isExpired(at: Date(timeIntervalSince1970: 1_000)))
        #expect(!payload.isExpired(at: Date(timeIntervalSince1970: 999)))
    }

    @Test(arguments: ["https://example.com", "pilothouse://pair", "pilothouse://pair?d=%%%", "pilothouse://other?d=e30"])
    func invalidLinksAreRejected(_ link: String) {
        #expect(throws: (any Error).self) { try PairingPayload(link: link) }
    }

    @Test func badKeyIsRejected() throws {
        var payload = makePayload()
        payload.pk = Base64URL.encode(Data([1, 2, 3]))
        let url = try #require(payload.url)
        #expect(throws: PairingPayload.ParseError.invalidKey) { try PairingPayload(link: url.absoluteString) }
    }

    @Test func qrPayloadStaysSmall() throws {
        let link = try #require(makePayload().url?.absoluteString)
        // Comfortably within a version 15 QR code at error correction level M.
        #expect(link.count < 600)
    }
}

/// Authorizer used by handshake tests.
struct TestAuthorizer: PeerAuthorizer {
    var decision: @Sendable (Data, ClientHandshakePayload) -> HandshakeDecision
    func authorize(publicKey: Data, hello: ClientHandshakePayload) async -> HandshakeDecision { decision(publicKey, hello) }
    func peerConnected(deviceId: String, hello: ClientHandshakePayload) async {}
    func peerDisconnected(deviceId: String) async {}
}

@Suite struct HandshakeTests {
    let mac = IdentityKeyPair.generate()
    let phone = IdentityKeyPair.generate()

    func hello(mode: ClientHandshakePayload.Mode = .connect, token: String? = nil, timestamp: Date = Date(), version: Int = PilothouseProtocol.version) -> ClientHandshakePayload {
        ClientHandshakePayload(
            protocolVersion: version, mode: mode, pairingToken: token, deviceName: "Test iPhone", platform: "iOS",
            appVersion: "1.0", timestamp: timestamp
        )
    }

    func runHandshake(
        macKeyOnPhone: Data? = nil,
        payload: ClientHandshakePayload,
        macNow: @escaping @Sendable () -> Date = { Date() },
        decide: @escaping @Sendable (Data, ClientHandshakePayload) -> HandshakeDecision = { _, _ in .accept }
    ) async -> (client: Result<(SecureChannel, ServerHandshakePayload), Error>, server: Result<AuthenticatedPeer, Error>) {
        let (clientTransport, serverTransport) = InMemoryTransport.makePair()
        let mac = self.mac
        let serverTask = Task {
            try await SecureHandshake.respond(over: serverTransport, identity: mac, macName: "Test Mac", now: macNow) { key, hello in
                decide(key, hello)
            }
        }
        let client: Result<(SecureChannel, ServerHandshakePayload), Error>
        do {
            let result = try await SecureHandshake.initiate(
                over: clientTransport, identity: phone, macPublicKey: macKeyOnPhone ?? mac.publicKey, payload: payload
            )
            client = .success((result.channel, result.server))
        } catch {
            client = .failure(error)
        }
        let server = await serverTask.result
        return (client, server)
    }

    @Test func successfulHandshakeAuthenticatesBothSides() async throws {
        let (client, server) = await runHandshake(payload: hello())
        let (channel, info) = try client.get()
        let peer = try server.get()
        #expect(info.accepted)
        #expect(info.macName == "Test Mac")
        #expect(info.macId == mac.fingerprint)
        #expect(peer.publicKey == phone.publicKey)
        #expect(peer.deviceId == phone.fingerprint)
        #expect(peer.hello.deviceName == "Test iPhone")
        #expect(channel.remoteStaticKey == mac.publicKey)
        #expect(channel.handshakeHash == peer.channel.handshakeHash)

        // Both directions carry data.
        try channel.send(Data("ping".utf8))
        #expect(try await peer.channel.receive() == Data("ping".utf8))
        try peer.channel.send(Data("pong".utf8))
        #expect(try await channel.receive() == Data("pong".utf8))
    }

    @Test func rejectionReasonReachesThePhone() async {
        let (client, server) = await runHandshake(payload: hello(mode: .pair, token: "wrong"), decide: { _, hello in
            hello.pairingToken == "right" ? .accept : .reject(ErrorPayload(code: .pairingTokenInvalid, message: "Expired or used code."))
        })
        guard case .failure(HandshakeError.rejected(let error)) = client else {
            Issue.record("Expected rejection, got \(client)")
            return
        }
        #expect(error.code == .pairingTokenInvalid)
        #expect(error.message == "Expired or used code.")
        guard case .failure = server else {
            Issue.record("Server should not yield a peer")
            return
        }
    }

    @Test func impostorMacCannotCompleteTheHandshake() async {
        // The phone pinned a different key (from the QR code) than the server holds:
        // a man-in-the-middle with its own key cannot decrypt message 1.
        let pinned = IdentityKeyPair.generate().publicKey
        let (client, server) = await runHandshake(macKeyOnPhone: pinned, payload: hello())
        guard case .failure = client, case .failure(HandshakeError.malformed) = server else {
            Issue.record("Handshake must fail: \(client) / \(server)")
            return
        }
    }

    @Test func clockSkewIsRejected() async {
        let (client, _) = await runHandshake(payload: hello(timestamp: Date().addingTimeInterval(-3_600)))
        guard case .failure(HandshakeError.rejected(let error)) = client else {
            Issue.record("Expected rejection, got \(client)")
            return
        }
        #expect(error.code == .clockSkew)
    }

    @Test func protocolMismatchIsExplained() async {
        let (client, _) = await runHandshake(payload: hello(version: 2))
        guard case .failure(HandshakeError.protocolMismatch) = client else {
            Issue.record("Expected protocol mismatch, got \(client)")
            return
        }
    }

    @Test func garbageFirstFrameIsDropped() async throws {
        let (clientTransport, serverTransport) = InMemoryTransport.makePair()
        let mac = self.mac
        let server = Task {
            try await SecureHandshake.respond(over: serverTransport, identity: mac, macName: "M") { _, _ in .accept }
        }
        try await clientTransport.send(Data([0x01]) + Data(repeating: 0xAB, count: 120))
        guard case .failure(HandshakeError.malformed) = await server.result else {
            Issue.record("Expected malformed")
            return
        }
    }
}

/// A transport wrapper that lets a test tamper with frames in flight.
final class TamperingTransport: MessageTransport, @unchecked Sendable {
    let inner: any MessageTransport
    let lock = NSLock()
    var captured: [Data] = []
    var peerDescription: String { "tampering" }

    init(_ inner: any MessageTransport) { self.inner = inner }

    func send(_ data: Data) async throws {
        lock.withLock { captured.append(data) }
        try await inner.send(data)
    }

    func receive() async throws -> Data { try await inner.receive() }
    func close() async { await inner.close() }
}

@Suite struct SecureChannelTests {
    func connectedPair() async throws -> (phone: SecureChannel, mac: SecureChannel, phoneTransport: TamperingTransport, rawToMac: InMemoryTransport) {
        let mac = IdentityKeyPair.generate()
        let phone = IdentityKeyPair.generate()
        let (clientTransport, serverTransport) = InMemoryTransport.makePair()
        let tampering = TamperingTransport(clientTransport)
        let server = Task {
            try await SecureHandshake.respond(over: serverTransport, identity: mac, macName: "M") { _, _ in .accept }
        }
        let (channel, _) = try await SecureHandshake.initiate(
            over: tampering, identity: phone, macPublicKey: mac.publicKey,
            payload: ClientHandshakePayload(mode: .connect, deviceName: "P", platform: "iOS", appVersion: "1")
        )
        let peer = try await server.value
        return (channel, peer.channel, tampering, clientTransport)
    }

    @Test func messagesArriveInOrder() async throws {
        let (phone, mac, _, _) = try await connectedPair()
        for index in 0..<200 {
            try phone.send(Data("m\(index)".utf8))
        }
        for index in 0..<200 {
            #expect(try await mac.receive() == Data("m\(index)".utf8))
        }
    }

    @Test func replayedFrameIsRejected() async throws {
        let (phone, mac, tampering, raw) = try await connectedPair()
        try phone.send(Data("transfer 1".utf8))
        #expect(try await mac.receive() == Data("transfer 1".utf8))
        // Wait until the frame was written, then replay it verbatim.
        while tampering.lock.withLock({ tampering.captured.count }) < 2 { await Task.yield() }
        let frame = tampering.lock.withLock { tampering.captured[1] }
        try await raw.send(frame)
        await #expect(throws: SecureChannelError.unexpectedCounter(expected: 1, received: 0)) {
            try await mac.receive()
        }
    }

    @Test func modifiedFrameIsRejected() async throws {
        let (phone, mac, tampering, raw) = try await connectedPair()
        try phone.send(Data("a".utf8))
        _ = try await mac.receive()
        while tampering.lock.withLock({ tampering.captured.count }) < 2 { await Task.yield() }
        var frame = tampering.lock.withLock { tampering.captured[1] }
        // Re-number it as the next frame (counter 1) but keep the old ciphertext.
        frame[8] = 1
        try await raw.send(frame)
        await #expect(throws: SecureChannelError.decryptionFailed) {
            try await mac.receive()
        }
    }

    @Test func closedChannelRefusesToSend() async throws {
        let (phone, _, _, _) = try await connectedPair()
        await phone.close()
        #expect(throws: SecureChannelError.closed) { try phone.send(Data()) }
    }
}
