import Foundation
import RemoteCodeKit
import SwiftData

/// A session summary cached for offline display (prompt §6.3).
@Model
final class CachedSession {
    @Attribute(.unique) var id: String
    var macId: String
    var summary: Data
    var updatedAt: Date

    init(id: String, macId: String, summary: Data, updatedAt: Date) {
        self.id = id
        self.macId = macId
        self.summary = summary
        self.updatedAt = updatedAt
    }
}

/// One persisted session event, keyed by `<sessionId>#<seq>`.
@Model
final class CachedEvent {
    @Attribute(.unique) var key: String
    var sessionId: String
    var seq: Int
    var event: Data

    init(sessionId: String, seq: Int, event: Data) {
        key = "\(sessionId)#\(seq)"
        self.sessionId = sessionId
        self.seq = seq
        self.event = event
    }
}

/// SwiftData-backed cache of sessions and transcripts.
@MainActor
final class TranscriptCache {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private let encoder = RemoteCodeJSON.encoder()
    private let decoder = RemoteCodeJSON.decoder()

    init(inMemory: Bool) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            container = try ModelContainer(for: CachedSession.self, CachedEvent.self, configurations: configuration)
        } catch {
            // A corrupt store must never keep the app from launching: fall back to memory.
            do {
                container = try ModelContainer(
                    for: CachedSession.self, CachedEvent.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            } catch {
                preconditionFailure("SwiftData is unavailable: \(error)")
            }
        }
    }

    // MARK: Sessions

    func sessions(macId: String) -> [SessionSummary] {
        let descriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { $0.macId == macId },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let cached = (try? context.fetch(descriptor)) ?? []
        return cached.compactMap { try? decoder.decode(SessionSummary.self, from: $0.summary) }
    }

    func store(_ sessions: [SessionSummary], macId: String, replacingAll: Bool) {
        if replacingAll {
            let ids = Set(sessions.map(\.id))
            let existing = (try? context.fetch(FetchDescriptor<CachedSession>(predicate: #Predicate { $0.macId == macId }))) ?? []
            for stale in existing where !ids.contains(stale.id) {
                deleteEvents(sessionId: stale.id)
                context.delete(stale)
            }
        }
        for session in sessions {
            store(session, macId: macId)
        }
    }

    func store(_ session: SessionSummary, macId: String) {
        guard let data = try? encoder.encode(session) else { return }
        let id = session.id
        if let existing = try? context.fetch(FetchDescriptor<CachedSession>(predicate: #Predicate { $0.id == id })).first {
            existing.summary = data
            existing.updatedAt = session.updatedAt
        } else {
            context.insert(CachedSession(id: id, macId: macId, summary: data, updatedAt: session.updatedAt))
        }
    }

    func deleteSession(_ id: String) {
        deleteEvents(sessionId: id)
        if let existing = try? context.fetch(FetchDescriptor<CachedSession>(predicate: #Predicate { $0.id == id })).first {
            context.delete(existing)
        }
    }

    // MARK: Events

    func events(sessionId: String) -> [SequencedEvent] {
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate { $0.sessionId == sessionId },
            sortBy: [SortDescriptor(\.seq)]
        )
        let cached = (try? context.fetch(descriptor)) ?? []
        return cached.compactMap { try? decoder.decode(SequencedEvent.self, from: $0.event) }
    }

    func append(_ event: SequencedEvent, sessionId: String) {
        guard !event.ephemeral, let data = try? encoder.encode(event) else { return }
        context.insert(CachedEvent(sessionId: sessionId, seq: event.seq, event: data))
    }

    func clearAll() {
        try? context.delete(model: CachedEvent.self)
        try? context.delete(model: CachedSession.self)
        try? context.save()
    }

    func save() {
        try? context.save()
    }

    private func deleteEvents(sessionId: String) {
        try? context.delete(model: CachedEvent.self, where: #Predicate { $0.sessionId == sessionId })
    }
}
