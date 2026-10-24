import Foundation

/// Errors raised while decoding protocol messages.
public enum ProtocolError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownMessageType(String)
    case unsupportedVersion(Int)
    case malformed(String)

    public var description: String {
        switch self {
        case .unknownMessageType(let type): "Unknown message type \"\(type)\""
        case .unsupportedVersion(let version):
            "Protocol version \(version) is not supported (this build speaks \(PilothouseProtocol.version))"
        case .malformed(let detail): "Malformed message: \(detail)"
        }
    }
}

/// `{ "v": 1, "id": "…", "re": "…", "ts": "…", "type": "…", "payload": { … } }`
///
/// * `v` — protocol version (`PilothouseProtocol.version`).
/// * `id` — unique message ID (UUID string).
/// * `re` — for responses: the `id` of the request being answered.
/// * `ts` — sender's clock; receivers reject messages far outside their own
///   clock (replay defence in depth, see SECURITY.md).
public struct ClientEnvelope: Sendable, Hashable, Codable {
    public var v: Int
    public var id: String
    public var ts: Date
    public var message: ClientMessage

    public init(id: String = UUID().uuidString, ts: Date = Date(), message: ClientMessage) {
        v = PilothouseProtocol.version
        self.id = id
        self.ts = ts
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case v, id, ts, type, payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        guard v == PilothouseProtocol.version else { throw ProtocolError.unsupportedVersion(v) }
        id = try container.decode(String.self, forKey: .id)
        ts = try container.decode(Date.self, forKey: .ts)
        let type = try container.decode(String.self, forKey: .type)
        func payload<T: Decodable>(_: T.Type) throws -> T {
            try container.decode(T.self, forKey: .payload)
        }
        switch type {
        case "hello": message = .hello(try payload(Hello.self))
        case "listDirectory": message = .listDirectory(try payload(ListDirectory.self))
        case "createDirectory": message = .createDirectory(try payload(CreateDirectory.self))
        case "listSessions": message = .listSessions
        case "startSession": message = .startSession(try payload(StartSession.self))
        case "resumeSession": message = .resumeSession(try payload(SessionRef.self))
        case "sendMessage": message = .sendMessage(try payload(SendMessage.self))
        case "interrupt": message = .interrupt(try payload(SessionRef.self))
        case "closeSession": message = .closeSession(try payload(SessionRef.self))
        case "deleteSession": message = .deleteSession(try payload(SessionRef.self))
        case "subscribe": message = .subscribe(try payload(Subscribe.self))
        case "unsubscribe": message = .unsubscribe(try payload(SessionRef.self))
        case "permissionResponse": message = .permissionResponse(try payload(PermissionResponse.self))
        case "macStatus": message = .macStatus
        case "getWeeklySummary": message = .getWeeklySummary(try payload(GetWeeklySummary.self))
        case "getUsageLimits": message = .getUsageLimits
        default: throw ProtocolError.unknownMessageType(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(id, forKey: .id)
        try container.encode(ts, forKey: .ts)
        try container.encode(message.typeName, forKey: .type)
        switch message {
        case .hello(let payload): try container.encode(payload, forKey: .payload)
        case .listDirectory(let payload): try container.encode(payload, forKey: .payload)
        case .createDirectory(let payload): try container.encode(payload, forKey: .payload)
        case .listSessions, .macStatus, .getUsageLimits: try container.encode(EmptyPayload(), forKey: .payload)
        case .getWeeklySummary(let payload): try container.encode(payload, forKey: .payload)
        case .startSession(let payload): try container.encode(payload, forKey: .payload)
        case .resumeSession(let payload), .interrupt(let payload), .closeSession(let payload),
            .deleteSession(let payload), .unsubscribe(let payload):
            try container.encode(payload, forKey: .payload)
        case .sendMessage(let payload): try container.encode(payload, forKey: .payload)
        case .subscribe(let payload): try container.encode(payload, forKey: .payload)
        case .permissionResponse(let payload): try container.encode(payload, forKey: .payload)
        }
    }
}

/// Envelope for messages from the Mac. Same shape as `ClientEnvelope` plus `re`.
public struct ServerEnvelope: Sendable, Hashable, Codable {
    public var v: Int
    public var id: String
    public var re: String?
    public var ts: Date
    public var message: ServerMessage

    public init(id: String = UUID().uuidString, re: String? = nil, ts: Date = Date(), message: ServerMessage) {
        v = PilothouseProtocol.version
        self.id = id
        self.re = re
        self.ts = ts
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case v, id, re, ts, type, payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        guard v == PilothouseProtocol.version else { throw ProtocolError.unsupportedVersion(v) }
        id = try container.decode(String.self, forKey: .id)
        re = try container.decodeIfPresent(String.self, forKey: .re)
        ts = try container.decode(Date.self, forKey: .ts)
        let type = try container.decode(String.self, forKey: .type)
        func payload<T: Decodable>(_: T.Type) throws -> T {
            try container.decode(T.self, forKey: .payload)
        }
        switch type {
        case "helloAck": message = .helloAck(try payload(HelloAck.self))
        case "ok": message = .ok
        case "directoryListing": message = .directoryListing(try payload(DirectoryListing.self))
        case "sessionList": message = .sessionList(try payload(SessionList.self))
        case "sessionStarted": message = .sessionStarted(try payload(SessionPayload.self))
        case "sessionUpdated": message = .sessionUpdated(try payload(SessionPayload.self))
        case "sessionDeleted": message = .sessionDeleted(try payload(SessionRef.self))
        case "event": message = .event(try payload(EventPayload.self))
        case "permissionRequest": message = .permissionRequest(try payload(PermissionRequest.self))
        case "permissionResolved": message = .permissionResolved(try payload(PermissionResolved.self))
        case "sessionEnded": message = .sessionEnded(try payload(SessionEnded.self))
        case "macStatus": message = .macStatus(try payload(MacStatus.self))
        case "weeklySummary": message = .weeklySummary(try payload(WeeklySummary.self))
        case "usageLimits": message = .usageLimits(try payload(UsageLimitsPayload.self))
        case "error": message = .error(try payload(ErrorPayload.self))
        default: throw ProtocolError.unknownMessageType(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(re, forKey: .re)
        try container.encode(ts, forKey: .ts)
        try container.encode(message.typeName, forKey: .type)
        switch message {
        case .helloAck(let payload): try container.encode(payload, forKey: .payload)
        case .ok: try container.encode(EmptyPayload(), forKey: .payload)
        case .directoryListing(let payload): try container.encode(payload, forKey: .payload)
        case .sessionList(let payload): try container.encode(payload, forKey: .payload)
        case .sessionStarted(let payload), .sessionUpdated(let payload): try container.encode(payload, forKey: .payload)
        case .sessionDeleted(let payload): try container.encode(payload, forKey: .payload)
        case .event(let payload): try container.encode(payload, forKey: .payload)
        case .permissionRequest(let payload): try container.encode(payload, forKey: .payload)
        case .permissionResolved(let payload): try container.encode(payload, forKey: .payload)
        case .sessionEnded(let payload): try container.encode(payload, forKey: .payload)
        case .macStatus(let payload): try container.encode(payload, forKey: .payload)
        case .weeklySummary(let payload): try container.encode(payload, forKey: .payload)
        case .usageLimits(let payload): try container.encode(payload, forKey: .payload)
        case .error(let payload): try container.encode(payload, forKey: .payload)
        }
    }
}

/// Peeks at the `v` field without decoding the rest, so a version mismatch can
/// be reported clearly instead of as a generic decoding failure.
public enum EnvelopeInspector {
    private struct VersionOnly: Decodable { var v: Int?; var id: String? }

    public static func version(of data: Data) -> Int? {
        (try? JSONDecoder().decode(VersionOnly.self, from: data))?.v
    }

    public static func messageId(of data: Data) -> String? {
        (try? JSONDecoder().decode(VersionOnly.self, from: data))?.id
    }
}
