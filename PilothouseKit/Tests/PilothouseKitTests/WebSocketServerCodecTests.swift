import Foundation
import Testing
@testable import PilothouseKit

/// The server half of `WebSocketCodec`, used by the Linux host (D-110).
@Suite struct WebSocketServerCodecTests {
    @Test func answersTheClientsOwnHandshake() throws {
        let key = WebSocketCodec.makeKey()
        let request = WebSocketCodec.handshakeRequest(host: "192.168.1.5", port: 47823, key: key)
        var buffer = request
        let end = try #require(WebSocketCodec.endOfHead(in: buffer))
        let head = String(decoding: buffer[buffer.startIndex..<(end - 4)], as: UTF8.self)
        buffer = Data(buffer[end...])
        #expect(buffer.isEmpty)

        let response = try WebSocketCodec.handshakeResponse(forRequest: head)
        let responseText = String(decoding: response, as: UTF8.self)
        #expect(responseText.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        #expect(responseText.hasSuffix("\r\n\r\n"))
        // The client accepts exactly this answer.
        // `\r\n` is one `Character`: drop the blank line that ends the head.
        try WebSocketCodec.validateResponse(String(responseText.dropLast(2)), key: key)
    }

    @Test func acceptsTheRFCExampleAndHeaderCase() throws {
        let head = "GET /chat HTTP/1.1\r\nHost: server.example.com\r\nUPGRADE: WebSocket\r\nconnection: Upgrade\r\nsec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13"
        let response = String(decoding: try WebSocketCodec.handshakeResponse(forRequest: head), as: UTF8.self)
        #expect(response.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
    }

    @Test func rejectsWhatIsNotAnUpgrade() {
        #expect(throws: WebSocketCodec.CodecError.self) {
            try WebSocketCodec.handshakeResponse(forRequest: "GET / HTTP/1.1\r\nHost: x")
        }
        #expect(throws: WebSocketCodec.CodecError.self) {
            try WebSocketCodec.handshakeResponse(forRequest: "POST / HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: k")
        }
        #expect(throws: WebSocketCodec.CodecError.self) {
            try WebSocketCodec.handshakeResponse(forRequest: "GET / HTTP/1.1\r\nUpgrade: websocket")
        }
    }

    @Test func clientFramesRoundTripWithEveryLengthEncoding() throws {
        for size in [0, 5, 125, 126, 65_535, 65_536, 300_000] {
            let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 * 13) })
            var buffer = WebSocketCodec.encode(.binary, payload: payload) + WebSocketCodec.encode(.ping, payload: Data("p".utf8))
            let frame = try #require(try WebSocketCodec.decodeClientFrame(&buffer))
            #expect(frame == .init(isFinal: true, opcode: .binary, payload: payload), "size \(size)")
            #expect(try WebSocketCodec.decodeClientFrame(&buffer) == .init(isFinal: true, opcode: .ping, payload: Data("p".utf8)))
            #expect(buffer.isEmpty)
        }
    }

    @Test func serverFramesAreUnmaskedAndReadByTheClient() throws {
        for size in [0, 125, 126, 70_000] {
            let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            var frame = WebSocketCodec.encodeServerFrame(.binary, payload: payload)
            #expect(frame[1] & 0x80 == 0, "server frames are not masked")
            #expect(try WebSocketCodec.decode(&frame) == .init(isFinal: true, opcode: .binary, payload: payload))
            #expect(frame.isEmpty)
        }
    }

    @Test func waitsForCompleteClientFramesAndRejectsUnmaskedOnes() throws {
        let full = WebSocketCodec.encode(.binary, payload: Data("hello".utf8), mask: [9, 8, 7, 6])
        var partial = Data(full.prefix(full.count - 1))
        #expect(try WebSocketCodec.decodeClientFrame(&partial) == nil)
        #expect(partial.count == full.count - 1, "nothing is consumed until the frame is complete")
        partial.append(full.last!)
        #expect(try WebSocketCodec.decodeClientFrame(&partial)?.payload == Data("hello".utf8))

        var unmasked = WebSocketCodec.encodeServerFrame(.binary, payload: Data("x".utf8))
        #expect(throws: WebSocketCodec.CodecError.unmaskedClientFrame) { try WebSocketCodec.decodeClientFrame(&unmasked) }
    }
}
