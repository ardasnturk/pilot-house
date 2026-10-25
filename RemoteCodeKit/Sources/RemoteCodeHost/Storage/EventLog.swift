import Foundation
import RemoteCodeKit

/// Creates private directories and files (0700 / 0600).
enum PrivateFiles {
    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Append-only JSON Lines log of one session's persisted events
/// (`~/Library/Application Support/Pilothouse/sessions/<id>.jsonl`).
///
/// Each line is a `SequencedEvent`. A torn last line (crash mid-write) is
/// ignored on load; sequence numbers continue after the last valid line.
///
/// Not thread-safe: owned by `SessionManager`, which serialises access and so
/// guarantees that events are broadcast in sequence order.
public final class EventLog {
    public let url: URL
    private var events: [SequencedEvent] = []
    private var handle: FileHandle?
    private var loaded = false

    public init(url: URL) {
        self.url = url
    }

    /// Sequence number of the newest event (0 if empty).
    public var lastSeq: Int {
        get throws {
            try loadIfNeeded()
            return events.last?.seq ?? 0
        }
    }

    /// Appends a persisted event and returns it with its sequence number.
    public func append(_ event: SessionEvent, thread: String? = nil, at date: Date = Date()) throws -> SequencedEvent {
        precondition(!event.isEphemeral, "Ephemeral events are not persisted")
        try loadIfNeeded()
        let sequenced = SequencedEvent(seq: (events.last?.seq ?? 0) + 1, timestamp: date, event: event, thread: thread)
        var line = try RemoteCodeJSON.encode(sequenced)
        line.append(0x0A)
        try fileHandle().write(contentsOf: line)
        events.append(sequenced)
        return sequenced
    }

    /// Events with `seq >= fromSeq`.
    public func events(from fromSeq: Int) throws -> [SequencedEvent] {
        try loadIfNeeded()
        guard let first = events.firstIndex(where: { $0.seq >= fromSeq }) else { return [] }
        return Array(events[first...])
    }

    /// Releases the file handle and the in-memory copy.
    public func close() {
        try? handle?.close()
        handle = nil
        events = []
        loaded = false
    }

    /// Deletes the log file.
    public func delete() {
        close()
        try? FileManager.default.removeItem(at: url)
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let decoder = RemoteCodeJSON.decoder()
        var lastSeq = 0
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let event = try? decoder.decode(SequencedEvent.self, from: Data(line)), event.seq > lastSeq else { continue }
            events.append(event)
            lastSeq = event.seq
        }
        // Drop a torn final line so the next append starts on a fresh line.
        if let last = data.last, last != 0x0A {
            let handle = try fileHandle()
            try handle.write(contentsOf: Data([0x0A]))
        }
    }

    private func fileHandle() throws -> FileHandle {
        if let handle { return handle }
        if !FileManager.default.fileExists(atPath: url.path) {
            try PrivateFiles.ensureDirectory(url.deletingLastPathComponent())
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.handle = handle
        return handle
    }
}

/// Everything the Mac remembers about a session besides its events.
public struct SessionRecord: Sendable, Hashable, Codable {
    public var summary: SessionSummary
    /// The CLI has a transcript for this session, so `--resume` will work.
    public var established: Bool
    /// "Always allow" keys granted for this session (see `PermissionRequest.rememberKey`).
    public var alwaysAllowed: [String]
    /// The user sent at least one message (the first one becomes the title).
    public var hasUserMessages: Bool
    /// The model the user asked for (`--model`); `summary.model` shows what the CLI reports.
    public var requestedModel: String?
    /// The agent's own conversation ID when it differs from `summary.id`
    /// (a Codex thread ID), used to resume the conversation.
    public var agentSessionId: String?
    /// Skills and plugin folders from the CLI's last `system/init` (the `/` menu).
    public var skills: [String]?
    public var plugins: [String: String]?

    public init(
        summary: SessionSummary, established: Bool = false, alwaysAllowed: [String] = [], hasUserMessages: Bool = false,
        requestedModel: String? = nil, agentSessionId: String? = nil
    ) {
        self.summary = summary
        self.established = established
        self.alwaysAllowed = alwaysAllowed
        self.hasUserMessages = hasUserMessages
        self.requestedModel = requestedModel
        self.agentSessionId = agentSessionId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(SessionSummary.self, forKey: .summary)
        established = try container.decodeIfPresent(Bool.self, forKey: .established) ?? false
        alwaysAllowed = try container.decodeIfPresent([String].self, forKey: .alwaysAllowed) ?? []
        hasUserMessages = try container.decodeIfPresent(Bool.self, forKey: .hasUserMessages) ?? false
        requestedModel = try container.decodeIfPresent(String.self, forKey: .requestedModel)
        agentSessionId = try container.decodeIfPresent(String.self, forKey: .agentSessionId)
        skills = try container.decodeIfPresent([String].self, forKey: .skills)
        plugins = try container.decodeIfPresent([String: String].self, forKey: .plugins)
    }
}

/// Persists session records in `sessions.json`.
public actor SessionStore {
    public nonisolated let url: URL
    private var records: [String: SessionRecord] = [:]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
            let decoded = try? RemoteCodeJSON.decode([SessionRecord].self, from: data)
        {
            records = Dictionary(decoded.map { ($0.summary.id, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    public var all: [SessionRecord] {
        records.values.sorted { $0.summary.updatedAt > $1.summary.updatedAt }
    }

    public func record(_ id: String) -> SessionRecord? {
        records[id]
    }

    public func upsert(_ record: SessionRecord) {
        records[record.summary.id] = record
        save()
    }

    public func remove(_ id: String) {
        records.removeValue(forKey: id)
        save()
    }

    private func save() {
        let sorted = records.values.sorted { $0.summary.createdAt < $1.summary.createdAt }
        guard let data = try? RemoteCodeJSON.encoder(pretty: true).encode(sorted) else { return }
        try? PrivateFiles.writeAtomically(data, to: url)
    }
}
