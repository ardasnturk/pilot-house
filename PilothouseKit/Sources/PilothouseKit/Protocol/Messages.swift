import Foundation

/// Version of the application protocol carried inside the encrypted channel.
/// Bump on any incompatible change and describe it in `docs/PROTOCOL.md`.
public enum PilothouseProtocol {
    public static let version = 1
    /// Bonjour service type advertised by the Mac.
    public static let bonjourServiceType = "_pilothouse._tcp"
    /// Default WebSocket port; the Mac tries the next ports if it is taken.
    public static let defaultPort = 47823
    /// How many consecutive ports the Mac tries.
    public static let portSearchRange = 20
}

/// Optional features a Mac announces in `HelloAck.capabilities`, so a newer
/// phone can hide what an older Mac cannot do without bumping `version`.
public enum HostCapability {
    public static let createDirectory = "createDirectory"
    /// `StartSession.agent`, `SessionSummary.agent` and `MacStatus.agents`.
    public static let agents = "agents"
    /// Session events carry `thread` and sub-agent threads are streamed.
    public static let threads = "threads"
    /// `getWeeklySummary` and `getUsageLimits`.
    public static let insights = "insights"
    /// Every capability this build of PilothouseKit implements.
    public static let all = [createDirectory, agents, threads, insights]
}

// MARK: - Shared payloads

public struct EmptyPayload: Sendable, Hashable, Codable {
    public init() {}
}

public struct SessionRef: Sendable, Hashable, Codable {
    public var sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
}

// MARK: - Client → Mac payloads

public struct Hello: Sendable, Hashable, Codable {
    public var protocolVersion: Int
    public var appVersion: String
    public var deviceName: String
    public var platform: String
    public init(protocolVersion: Int = PilothouseProtocol.version, appVersion: String, deviceName: String, platform: String) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.deviceName = deviceName
        self.platform = platform
    }
}

public struct ListDirectory: Sendable, Hashable, Codable {
    /// Absolute path or `~`-relative path; `nil` means the home folder.
    public var path: String?
    public var showHidden: Bool
    public init(path: String? = nil, showHidden: Bool = false) {
        self.path = path
        self.showHidden = showHidden
    }
}

public struct CreateDirectory: Sendable, Hashable, Codable {
    /// Folder to create the new folder in (same rules as `ListDirectory.path`).
    public var parent: String
    /// Name of the new folder: a single path component.
    public var name: String
    public init(parent: String, name: String) {
        self.parent = parent
        self.name = name
    }
}

public struct StartSession: Sendable, Hashable, Codable {
    public var cwd: String
    public var model: String?
    public var permissionMode: PermissionMode?
    public var firstMessage: String?
    /// Agent CLI to run; `nil` means Claude Code (capability `agents`).
    public var agent: AgentKind?
    public init(
        cwd: String, model: String? = nil, permissionMode: PermissionMode? = nil, firstMessage: String? = nil,
        agent: AgentKind? = nil
    ) {
        self.cwd = cwd
        self.model = model
        self.permissionMode = permissionMode
        self.firstMessage = firstMessage
        self.agent = agent
    }
}

/// An image sent with a message (base64 inside JSON; max 5 MB decoded).
public struct MessageAttachment: Sendable, Hashable, Codable {
    public static let maxBytes = 5 * 1024 * 1024
    /// `image/jpeg`, `image/png`, `image/gif` or `image/webp`.
    public var mediaType: String
    public var data: Data
    public var filename: String?
    public init(mediaType: String, data: Data, filename: String? = nil) {
        self.mediaType = mediaType
        self.data = data
        self.filename = filename
    }

    public static let supportedMediaTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]
}

public struct SendMessage: Sendable, Hashable, Codable {
    public var sessionId: String
    public var text: String
    public var attachments: [MessageAttachment]?
    public init(sessionId: String, text: String, attachments: [MessageAttachment]? = nil) {
        self.sessionId = sessionId
        self.text = text
        self.attachments = attachments
    }
}

public struct Subscribe: Sendable, Hashable, Codable {
    public var sessionId: String
    /// First sequence number the client has not seen (1 for a fresh client).
    public var fromSeq: Int
    public init(sessionId: String, fromSeq: Int) {
        self.sessionId = sessionId
        self.fromSeq = fromSeq
    }
}

public struct PermissionResponse: Sendable, Hashable, Codable {
    public var requestId: String
    public var allow: Bool
    /// "Always allow in this session" (see `PermissionRequest.rememberKey`).
    public var remember: Bool?
    public init(requestId: String, allow: Bool, remember: Bool? = nil) {
        self.requestId = requestId
        self.allow = allow
        self.remember = remember
    }
}

// MARK: - Mac → client payloads

public struct HelloAck: Sendable, Hashable, Codable {
    public var protocolVersion: Int
    public var macName: String
    public var macId: String
    public var serverVersion: String
    /// Permission requests waiting for an answer when the client connected.
    public var pendingPermissions: [PermissionRequest]
    /// Optional features (`HostCapability`); missing on Macs older than 1.1.
    public var capabilities: [String]?
    public init(
        protocolVersion: Int = PilothouseProtocol.version, macName: String, macId: String, serverVersion: String,
        pendingPermissions: [PermissionRequest] = [], capabilities: [String]? = HostCapability.all
    ) {
        self.protocolVersion = protocolVersion
        self.macName = macName
        self.macId = macId
        self.serverVersion = serverVersion
        self.pendingPermissions = pendingPermissions
        self.capabilities = capabilities
    }

    public func supports(_ capability: String) -> Bool { capabilities?.contains(capability) ?? false }
}

public struct SessionList: Sendable, Hashable, Codable {
    public var sessions: [SessionSummary]
    public init(sessions: [SessionSummary]) { self.sessions = sessions }
}

public struct SessionPayload: Sendable, Hashable, Codable {
    public var session: SessionSummary
    public init(session: SessionSummary) { self.session = session }
}

public struct EventPayload: Sendable, Hashable, Codable {
    public var sessionId: String
    public var seq: Int
    public var ts: Date
    public var ephemeral: Bool?
    public var payload: SessionEvent
    /// Sub-agent thread (capability `threads`); `nil` for the main conversation.
    public var thread: String?
    public init(sessionId: String, event: SequencedEvent) {
        self.sessionId = sessionId
        seq = event.seq
        ts = event.timestamp
        ephemeral = event.ephemeral ? true : nil
        payload = event.event
        thread = event.thread
    }

    public var sequencedEvent: SequencedEvent {
        SequencedEvent(seq: seq, timestamp: ts, ephemeral: ephemeral ?? false, event: payload, thread: thread)
    }
}

public struct PermissionResolved: Sendable, Hashable, Codable {
    public var requestId: String
    public var sessionId: String
    public var outcome: SessionEvent.PermissionDecision.Outcome
    public init(requestId: String, sessionId: String, outcome: SessionEvent.PermissionDecision.Outcome) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.outcome = outcome
    }
}

public struct SessionEnded: Sendable, Hashable, Codable {
    public enum Reason: String, Sendable, Hashable, Codable {
        case closedByUser
        case deleted
        case processFailed
        case macShuttingDown
    }
    public var sessionId: String
    public var reason: Reason
    public var message: String?
    public init(sessionId: String, reason: Reason, message: String? = nil) {
        self.sessionId = sessionId
        self.reason = reason
        self.message = message
    }
}

/// Error codes are open-ended strings so newer Macs can add codes.
public struct ErrorCode: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let protocolMismatch = ErrorCode("protocolMismatch")
    public static let invalidRequest = ErrorCode("invalidRequest")
    public static let unknownMessage = ErrorCode("unknownMessage")
    public static let notFound = ErrorCode("notFound")
    public static let pathOutsideHome = ErrorCode("pathOutsideHome")
    /// macOS privacy (TCC) blocked access; `message` says which permission to grant.
    public static let privacyPermissionRequired = ErrorCode("privacyPermissionRequired")
    public static let notADirectory = ErrorCode("notADirectory")
    public static let alreadyExists = ErrorCode("alreadyExists")
    public static let invalidName = ErrorCode("invalidName")
    public static let claudeNotInstalled = ErrorCode("claudeNotInstalled")
    public static let agentNotInstalled = ErrorCode("agentNotInstalled")
    public static let sessionClosed = ErrorCode("sessionClosed")
    public static let modeNotAllowed = ErrorCode("modeNotAllowed")
    public static let unauthorized = ErrorCode("unauthorized")
    public static let deviceRevoked = ErrorCode("deviceRevoked")
    public static let pairingTokenInvalid = ErrorCode("pairingTokenInvalid")
    public static let clockSkew = ErrorCode("clockSkew")
    public static let timeout = ErrorCode("timeout")
    public static let internalError = ErrorCode("internal")
}

public struct ErrorPayload: Sendable, Hashable, Codable, Error {
    public var code: ErrorCode
    public var message: String
    public init(code: ErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - Message enums

/// Messages sent by the phone.
public enum ClientMessage: Sendable, Hashable {
    case hello(Hello)
    case listDirectory(ListDirectory)
    case createDirectory(CreateDirectory)
    case listSessions
    case startSession(StartSession)
    case resumeSession(SessionRef)
    case sendMessage(SendMessage)
    case interrupt(SessionRef)
    case closeSession(SessionRef)
    case deleteSession(SessionRef)
    case subscribe(Subscribe)
    case unsubscribe(SessionRef)
    case permissionResponse(PermissionResponse)
    case macStatus
    case getWeeklySummary(GetWeeklySummary)
    case getUsageLimits

    public var typeName: String {
        switch self {
        case .hello: "hello"
        case .listDirectory: "listDirectory"
        case .createDirectory: "createDirectory"
        case .listSessions: "listSessions"
        case .startSession: "startSession"
        case .resumeSession: "resumeSession"
        case .sendMessage: "sendMessage"
        case .interrupt: "interrupt"
        case .closeSession: "closeSession"
        case .deleteSession: "deleteSession"
        case .subscribe: "subscribe"
        case .unsubscribe: "unsubscribe"
        case .permissionResponse: "permissionResponse"
        case .macStatus: "macStatus"
        case .getWeeklySummary: "getWeeklySummary"
        case .getUsageLimits: "getUsageLimits"
        }
    }
}

/// Messages sent by the Mac.
public enum ServerMessage: Sendable, Hashable {
    case helloAck(HelloAck)
    case ok
    case directoryListing(DirectoryListing)
    case sessionList(SessionList)
    case sessionStarted(SessionPayload)
    case sessionUpdated(SessionPayload)
    case sessionDeleted(SessionRef)
    case event(EventPayload)
    case permissionRequest(PermissionRequest)
    case permissionResolved(PermissionResolved)
    case sessionEnded(SessionEnded)
    case macStatus(MacStatus)
    case weeklySummary(WeeklySummary)
    case usageLimits(UsageLimitsPayload)
    case error(ErrorPayload)

    public var typeName: String {
        switch self {
        case .helloAck: "helloAck"
        case .ok: "ok"
        case .directoryListing: "directoryListing"
        case .sessionList: "sessionList"
        case .sessionStarted: "sessionStarted"
        case .sessionUpdated: "sessionUpdated"
        case .sessionDeleted: "sessionDeleted"
        case .event: "event"
        case .permissionRequest: "permissionRequest"
        case .permissionResolved: "permissionResolved"
        case .sessionEnded: "sessionEnded"
        case .macStatus: "macStatus"
        case .weeklySummary: "weeklySummary"
        case .usageLimits: "usageLimits"
        case .error: "error"
        }
    }
}
