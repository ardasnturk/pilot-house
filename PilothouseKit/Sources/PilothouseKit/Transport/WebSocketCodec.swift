import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The client side of RFC 6455, enough for Remote Code: the opening handshake
/// and binary, ping, pong and close frames. Used instead of Network.framework's
/// WebSocket protocol, whose client connections iOS aborts on the local
/// network (ECONNABORTED right after the TCP handshake; D-108). Pure, so it is
/// tested on every platform.
public enum WebSocketCodec {
    public enum Opcode: UInt8, Sendable {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    public struct Frame: Sendable, Equatable {
        public var isFinal: Bool
        public var opcode: Opcode
        public var payload: Data
    }

    public enum CodecError: Error, Equatable, CustomStringConvertible {
        case handshakeRejected(String)
        case badAccept
        case reservedBits
        case unknownOpcode(UInt8)
        case maskedServerFrame
        case frameTooLarge

        public var description: String {
            switch self {
            case .handshakeRejected(let status): "WebSocket handshake rejected (\(status))"
            case .badAccept: "WebSocket handshake: wrong Sec-WebSocket-Accept"
            case .reservedBits: "WebSocket frame with reserved bits"
            case .unknownOpcode(let code): "WebSocket frame with unknown opcode \(code)"
            case .maskedServerFrame: "WebSocket server frame is masked"
            case .frameTooLarge: "WebSocket frame too large"
            }
        }
    }

    static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// A fresh base64 `Sec-WebSocket-Key`.
    public static func makeKey() -> String {
        Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
    }

    public static func handshakeRequest(host: String, port: Int, key: String) -> Data {
        let hostHeader = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let request = [
            "GET / HTTP/1.1",
            "Host: \(hostHeader)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "", "",
        ].joined(separator: "\r\n")
        return Data(request.utf8)
    }

    public static func expectedAccept(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + acceptGUID).utf8))).base64EncodedString()
    }

    /// Checks the server's response head (without the trailing blank line).
    public static func validateResponse(_ head: String, key: String) throws {
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first ?? ""
        guard status.split(separator: " ").dropFirst().first == "101" else {
            throw CodecError.handshakeRejected(status)
        }
        let accept = lines.dropFirst().first { $0.lowercased().hasPrefix("sec-websocket-accept:") }
            .map { String($0.drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard accept == expectedAccept(for: key) else { throw CodecError.badAccept }
    }

    /// Index just past the `\r\n\r\n` ending an HTTP head, if complete.
    public static func endOfHead(in buffer: Data) -> Data.Index? {
        buffer.range(of: Data("\r\n\r\n".utf8))?.upperBound
    }

    /// One client frame: always final and masked, as RFC 6455 requires.
    public static func encode(_ opcode: Opcode, payload: Data, mask: [UInt8] = (0..<4).map { _ in UInt8.random(in: .min ... .max) }) -> Data {
        var frame = Data([0x80 | opcode.rawValue])
        let count = payload.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(0x80 | 126)
            frame.append(UInt8(count >> 8))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(contentsOf: mask)
        var masked = [UInt8](payload)
        for index in masked.indices { masked[index] ^= mask[index & 3] }
        frame.append(contentsOf: masked)
        return frame
    }

    /// Takes one complete server frame off the front of `buffer`, or returns
    /// `nil` when more bytes are needed.
    public static func decode(_ buffer: inout Data, maximumSize: Int = maximumMessageSize) throws -> Frame? {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return nil }
        guard bytes[0] & 0x70 == 0 else { throw CodecError.reservedBits }
        guard let opcode = Opcode(rawValue: bytes[0] & 0x0F) else { throw CodecError.unknownOpcode(bytes[0] & 0x0F) }
        let isMasked = bytes[1] & 0x80 != 0
        guard !isMasked else { throw CodecError.maskedServerFrame }
        var length = Int(bytes[1] & 0x7F)
        var headerLength = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            headerLength = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            var value: UInt64 = 0
            for index in 2..<10 { value = value << 8 | UInt64(bytes[index]) }
            guard value <= UInt64(maximumSize) else { throw CodecError.frameTooLarge }
            length = Int(value)
            headerLength = 10
        }
        guard length <= maximumSize else { throw CodecError.frameTooLarge }
        guard buffer.count >= headerLength + length else { return nil }
        let start = buffer.startIndex + headerLength
        let payload = Data(buffer[start..<(start + length)])
        buffer = Data(buffer[(start + length)...])
        return Frame(isFinal: bytes[0] & 0x80 != 0, opcode: opcode, payload: payload)
    }
}
