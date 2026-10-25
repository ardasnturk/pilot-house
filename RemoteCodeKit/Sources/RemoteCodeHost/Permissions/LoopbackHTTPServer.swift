import Foundation
import RemoteCodeKit
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A parsed HTTP/1.1 request. Header names are lower-cased.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func text(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }

    static func json(_ status: Int, _ value: JSONValue) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(value.jsonString().utf8))
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        default: "Error"
        }
    }

    public func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = keepAlive ? "keep-alive" : "close"
        allHeaders["Cache-Control"] = "no-store"
        for (name, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// Incremental HTTP/1.1 request parser (Content-Length and chunked bodies).
public struct HTTPRequestParser: Sendable {
    public enum ParseError: Error, Sendable, Equatable {
        case malformed
        case tooLarge
    }

    public static let maximumHeaderBytes = 64 * 1024
    public static let maximumBodyBytes = 8 * 1024 * 1024
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete request, or `nil` if more bytes are needed.
    public mutating func next() throws -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            if buffer.count > Self.maximumHeaderBytes { throw ParseError.tooLarge }
            return nil
        }
        let headerText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw ParseError.malformed }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { throw ParseError.malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let bodyStart = headerEnd.upperBound
        let body: Data
        let consumed: Int
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let (decoded, end) = try Self.decodeChunked(buffer, from: bodyStart) else { return nil }
            body = decoded
            consumed = end - buffer.startIndex
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard length >= 0 else { throw ParseError.malformed }
            guard length <= Self.maximumBodyBytes else { throw ParseError.tooLarge }
            guard buffer.endIndex - bodyStart >= length else { return nil }
            body = Data(buffer[bodyStart..<(bodyStart + length)])
            consumed = bodyStart + length - buffer.startIndex
        }
        buffer = Data(buffer.dropFirst(consumed))
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
    }

    /// Returns the decoded body and the index after it, or `nil` if incomplete.
    private static func decodeChunked(_ data: Data, from start: Data.Index) throws -> (Data, Data.Index)? {
        var index = start
        var body = Data()
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return nil }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { throw ParseError.malformed }
            index = lineEnd.upperBound
            if size == 0 {
                // Skip optional trailers up to the final CRLF.
                guard let end = data.range(of: crlf, in: index..<data.endIndex) else { return nil }
                return (body, end.upperBound)
            }
            guard data.endIndex - index >= size + 2 else { return nil }
            body.append(data[index..<(index + size)])
            guard body.count <= maximumBodyBytes else { throw ParseError.tooLarge }
            index += size + 2
        }
    }
}

/// A tiny blocking HTTP/1.1 server bound to `127.0.0.1` on an ephemeral port.
///
/// BSD sockets + one thread per connection: it only ever serves the local
/// Claude CLI processes (a handful of keep-alive connections), and blocking a
/// dedicated thread while a permission request waits up to 10 minutes is
/// harmless. Works identically on macOS and Linux, so it is covered by tests.
/// The owner must call `stop()`; the accept thread keeps the server alive.
public final class LoopbackHTTPServer: Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public let port: Int
    private let listenSocket: Int32
    private let handler: Handler
    private let connections = Mutex<Set<Int32>>([])
    private let stopped = Mutex(false)

    /// Binds and starts serving immediately.
    public init(handler: @escaping Handler) throws {
        self.handler = handler
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw ChildProcessError.pipeFailed(errno: errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw ChildProcessError.pipeFailed(errno: code)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
        listenSocket = fd

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "remotecode.mcp.accept"
        thread.start()
    }

    deinit {
        stop()
    }

    /// Closes the listening socket and all connections.
    public func stop() {
        let wasStopped = stopped.withLock { value -> Bool in
            defer { value = true }
            return value
        }
        guard !wasStopped else { return }
        shutdown(listenSocket, Int32(SHUT_RDWR))
        close(listenSocket)
        for fd in connections.withLock({ $0 }) {
            shutdown(fd, Int32(SHUT_RDWR))
        }
    }

    private var isStopped: Bool { stopped.withLock { $0 } }

    private func acceptLoop() {
        while !isStopped {
            let client = accept(listenSocket, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            #if canImport(Darwin)
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            #endif
            connections.withLock { _ = $0.insert(client) }
            let thread = Thread { [weak self] in
                self?.serve(client)
                close(client)
                _ = self?.connections.withLock { $0.remove(client) }
            }
            thread.name = "remotecode.mcp.connection"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        var parser = HTTPRequestParser()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !isStopped {
            let request: HTTPRequest?
            do {
                request = try parser.next()
            } catch {
                send(HTTPResponse.text(400, "Bad Request").serialized(keepAlive: false), to: fd)
                return
            }
            if let request {
                let response = runBlocking { await self.handler(request) }
                let keepAlive = request.headers["connection"]?.lowercased() != "close"
                guard send(response.serialized(keepAlive: keepAlive), to: fd), keepAlive else { return }
                continue
            }
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count > 0 {
                parser.append(Data(buffer[0..<count]))
            } else if count == 0 || errno != EINTR {
                return
            }
        }
    }

    @discardableResult
    private func send(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                #if canImport(Darwin)
                let sent = Darwin.send(fd, pointer, remaining, 0)
                #else
                let sent = Glibc.send(fd, pointer, remaining, Int32(MSG_NOSIGNAL))
                #endif
                if sent < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= sent
                pointer = pointer.advanced(by: sent)
            }
            return true
        }
    }

    /// Bridges the async handler onto this dedicated connection thread.
    private func runBlocking(_ operation: @escaping @Sendable () async -> HTTPResponse) -> HTTPResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        Task {
            box.set(await operation())
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? .text(500, "Internal Server Error")
    }
}

private final class ResponseBox: Sendable {
    private let storage = Mutex<HTTPResponse?>(nil)
    func set(_ response: HTTPResponse) { storage.withLock { $0 = response } }
    var value: HTTPResponse? { storage.withLock { $0 } }
}
