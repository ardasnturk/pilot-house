import Foundation
import PilothouseHost
import PilothouseKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// The running host and the `pair` / `status` / `devices` commands talk over
// HTTP on 127.0.0.1 (D-110). The port and a random token are in
// `control.json` in the data folder, readable only by its owner.

struct ControlFile: Codable {
    var port: Int
    var token: String
    var pid: Int32
}

struct ControlPairing: Codable {
    var link: String
    var verificationCode: String
    var expiresAt: Int
    var addresses: [String]
    var port: Int
}

struct ControlStatus: Codable {
    struct Agent: Codable {
        var name: String
        var installed: Bool
        var version: String?
        var loggedIn: Bool?
        var delegation: Bool
    }

    var name: String
    var version: String
    var protocolVersion: Int
    var fingerprint: String
    var port: Int
    var addresses: [String]
    var homeDirectory: String
    var claude: String
    var agents: [Agent]
    var pairedDevices: Int
    var connectedDevices: Int
    var sessions: Int
    var activeSessions: Int
    var bypassPermissionsAllowed: Bool
    var ntfy: Bool
}

struct ControlDevice: Codable {
    var id: String
    var name: String
    var platform: String
    var pairedAt: Double
    var lastSeenAt: Double?
    var connected: Bool
}

struct ControlMessage: Codable {
    var message: String
}

/// Serves the control requests of one running host.
final class ControlServer: Sendable {
    private let server: LoopbackHTTPServer
    private let url: URL

    init(host: LinuxHost, url: URL) throws {
        let token = Base64URL.encode(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        server = try LoopbackHTTPServer { request in
            guard request.headers["authorization"] == "Bearer \(token)" else {
                return Self.json(401, ControlMessage(message: "Wrong control token."))
            }
            do {
                switch (request.method, request.path) {
                case ("GET", "/health"):
                    return Self.json(200, ControlMessage(message: "ok"))
                case ("POST", "/pair"):
                    return Self.json(200, try await host.pairingInvitation())
                case ("GET", "/status"):
                    return Self.json(200, await host.controlStatus())
                case ("GET", "/devices"):
                    return Self.json(200, await host.controlDevices())
                case ("POST", "/revoke"):
                    let id = String(decoding: request.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    return Self.json(200, try await host.revoke(prefix: id))
                default:
                    return Self.json(404, ControlMessage(message: "Unknown request \(request.method) \(request.path)."))
                }
            } catch {
                return Self.json(400, ControlMessage(message: String(describing: error)))
            }
        }
        self.url = url
        let file = ControlFile(port: server.port, token: token, pid: getpid())
        try FileIdentityStore.writePrivately(try JSONEncoder().encode(file), to: url)
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: url)
    }

    private static func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        let body = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }
}

/// Sends one request to the running host.
struct ControlClient {
    let file: ControlFile

    init(url: URL) throws {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(ControlFile.self, from: data) else {
            throw OptionError("Pilothouse is not running (no \(url.path)). Start it first, e.g. `docker compose up -d`.")
        }
        self.file = file
    }

    func request<T: Decodable>(_ method: String, _ path: String, body: String = "", as type: T.Type) throws -> T {
        let (status, data) = try send(method: method, path: path, body: Data(body.utf8))
        guard status == 200 else {
            let message = (try? JSONDecoder().decode(ControlMessage.self, from: data))?.message ?? "HTTP \(status)"
            throw OptionError(message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A blocking HTTP/1.1 exchange with `Connection: close` on 127.0.0.1.
    private func send(method: String, path: String, body: Data) throws -> (Int, Data) {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw OptionError("No socket: errno \(errno)") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(file.port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            throw OptionError("Pilothouse is not running (nothing on the control port \(file.port)). Start it first, e.g. `docker compose up -d`.")
        }
        let head = [
            "\(method) \(path) HTTP/1.1",
            "Host: 127.0.0.1",
            "Authorization: Bearer \(file.token)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "", "",
        ].joined(separator: "\r\n")
        let request = Data(head.utf8) + body
        let sent = request.withUnsafeBytes { socketSend(fd, $0.baseAddress, $0.count) }
        guard sent == request.count else { throw OptionError("Could not talk to Pilothouse (errno \(errno)).") }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count > 0 {
                response.append(contentsOf: buffer[0..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        guard let end = response.range(of: Data("\r\n\r\n".utf8)) else { throw OptionError("Pilothouse sent no answer.") }
        let statusLine = String(decoding: response[response.startIndex..<end.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n").first ?? ""
        let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
        return (status, Data(response[end.upperBound...]))
    }
}

private func socketSend(_ fd: Int32, _ pointer: UnsafeRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.send(fd, pointer, count, 0)
    #else
    Glibc.send(fd, pointer, count, Int32(MSG_NOSIGNAL))
    #endif
}
