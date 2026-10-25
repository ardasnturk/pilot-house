import Foundation
import Testing
@testable import RemoteCodeKit

@Suite struct WebSocketCodecTests {
    @Test func acceptValueMatchesRFC6455() throws {
        // The worked example of RFC 6455 §1.3.
        #expect(WebSocketCodec.expectedAccept(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        try WebSocketCodec.validateResponse(head, key: "dGhlIHNhbXBsZSBub25jZQ==")
        #expect(throws: WebSocketCodec.CodecError.badAccept) {
            try WebSocketCodec.validateResponse(head, key: "AAAAAAAAAAAAAAAAAAAAAA==")
        }
        #expect(throws: WebSocketCodec.CodecError.handshakeRejected("HTTP/1.1 400 Bad Request")) {
            try WebSocketCodec.validateResponse("HTTP/1.1 400 Bad Request", key: "x")
        }
    }

    @Test func requestHasTheUpgradeHeaders() {
        let request = String(decoding: WebSocketCodec.handshakeRequest(host: "192.168.1.5", port: 47823, key: "k"), as: UTF8.self)
        #expect(request.hasPrefix("GET / HTTP/1.1\r\nHost: 192.168.1.5:47823\r\n"))
        #expect(request.contains("Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: k\r\nSec-WebSocket-Version: 13\r\n\r\n"))
        #expect(String(decoding: WebSocketCodec.handshakeRequest(host: "fd7a::1", port: 1, key: "k"), as: UTF8.self).contains("Host: [fd7a::1]:1"))
    }

    @Test func clientFramesAreMaskedWithEveryLengthEncoding() throws {
        for size in [0, 5, 125, 126, 65_535, 65_536, 300_000] {
            let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 * 7) })
            let frame = WebSocketCodec.encode(.binary, payload: payload, mask: [1, 2, 3, 4])
            #expect(frame[0] == 0x82)
            #expect(frame[1] & 0x80 == 0x80, "client frames are masked")
            // Unmask like a server would, then decode the server-style frame.
            let lengthByte = Int(frame[1] & 0x7F)
            let header = lengthByte < 126 ? 2 : (lengthByte == 126 ? 4 : 10)
            let mask = [UInt8](frame[header..<(header + 4)])
            var body = [UInt8](frame[(header + 4)...])
            for index in body.indices { body[index] ^= mask[index & 3] }
            #expect(Data(body) == payload, "size \(size)")
            var serverFrame = Data([0x82]) + frame[1..<header] + Data(body)
            serverFrame[1] &= 0x7F
            let decoded = try #require(try WebSocketCodec.decode(&serverFrame))
            #expect(decoded.payload == payload)
            #expect(serverFrame.isEmpty)
        }
    }

    @Test func decodeWaitsForCompleteFramesAndKeepsTheRest() throws {
        var buffer = Data([0x82, 0x03, 0x61])
        #expect(try WebSocketCodec.decode(&buffer) == nil)
        buffer.append(contentsOf: [0x62, 0x63, 0x89, 0x00])
        #expect(try WebSocketCodec.decode(&buffer) == .init(isFinal: true, opcode: .binary, payload: Data("abc".utf8)))
        #expect(try WebSocketCodec.decode(&buffer) == .init(isFinal: true, opcode: .ping, payload: Data()))
        #expect(buffer.isEmpty)
        var masked = Data([0x82, 0x81, 1, 2, 3, 4, 5])
        #expect(throws: WebSocketCodec.CodecError.maskedServerFrame) { try WebSocketCodec.decode(&masked) }
    }
}

#if canImport(Network)
/// The new client against the Mac's real Network.framework WebSocket server.
@Suite(.serialized) struct TCPWebSocketTransportTests {
    @Test func talksToTheMacListener() async throws {
        let listener = WebSocketListener()
        let server = AsyncQueue<any MessageTransport>()
        let port = try await listener.start(
            configuration: .init(preferredPort: 48_900, portSearchRange: 50, bonjourName: "Test-\(UUID().uuidString.prefix(6))", txtRecord: [:])
        ) { transport in Task { await server.push(transport) } }
        defer { listener.stop() }

        let client = try await TCPWebSocketTransport.connect(to: .hostPort(host: "127.0.0.1", port: port), timeout: 5)
        let serverEnd = try await server.pop()

        try await client.send(Data("hello".utf8))
        #expect(try await serverEnd.receive() == Data("hello".utf8))
        let large = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0) })
        try await serverEnd.send(large)
        #expect(try await client.receive() == large)
        try await client.send(large)
        #expect(try await serverEnd.receive() == large)

        // Pongs are handled while both ends read, as in MacClient and ServerConnection.
        let reader = Task { try await client.receive() }
        let serverReader = Task { try await serverEnd.receive() }
        try await client.ping(timeout: 3)
        try await serverEnd.send(Data("after ping".utf8))
        #expect(try await reader.value == Data("after ping".utf8))
        try await client.send(Data("bye".utf8))
        #expect(try await serverReader.value == Data("bye".utf8))

        await client.close()
        await #expect(throws: (any Error).self) { _ = try await serverEnd.receive() }
    }
}
#endif
