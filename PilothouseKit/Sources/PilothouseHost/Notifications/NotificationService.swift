import Foundation
import PilothouseKit
import Synchronization

/// Something worth telling the user about while they are away from the phone
/// app (docs/DECISIONS.md D-095).
public struct HostAlert: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        /// A turn started from a phone has finished.
        case turnFinished
        /// Claude waits for a permission decision.
        case permissionRequested
        /// The CLI crashed, could not start or the turn ended with an error.
        case sessionFailed
        /// A sub-agent of a session has finished (`delegate_to_agent`), posted
        /// by `HostRuntime` when the delegation returns.
        case subagentFinished
    }

    public var kind: Kind
    public var sessionId: String
    /// Last path component of the session's working directory.
    public var folderName: String
    /// Optional detail: the last assistant message, the tool waiting for
    /// approval, the error text or the sub-agent's name. Only shown when the
    /// user opted into summaries.
    public var detail: String?

    public init(kind: Kind, sessionId: String, folderName: String, detail: String? = nil) {
        self.kind = kind
        self.sessionId = sessionId
        self.folderName = folderName
        self.detail = detail
    }
}

/// Title and body of a notification, already localised.
public struct AlertContent: Sendable, Hashable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    /// Longest detail appended to a notification body.
    public static let maximumDetailLength = 160

    /// Plain English text, used by tests and as a fallback. The apps pass a
    /// localised formatter instead.
    public static func english(for alert: HostAlert, includeDetail: Bool) -> AlertContent {
        let headline = switch alert.kind {
        case .turnFinished: "Task finished · \(alert.folderName)"
        case .permissionRequested: "Approval needed · \(alert.folderName)"
        case .sessionFailed: "Session failed · \(alert.folderName)"
        case .subagentFinished: "Sub-agent finished · \(alert.folderName)"
        }
        return AlertContent(title: "Pilothouse", body: body(headline, detail: includeDetail ? alert.detail : nil))
    }

    /// `headline`, plus a shortened `detail` on a second line.
    public static func body(_ headline: String, detail: String?) -> String {
        guard let short = detail.flatMap(shortened) else { return headline }
        return "\(headline)\n\(short)"
    }

    /// `detail` on one line and at most `maximumDetailLength` characters; `nil` if blank.
    public static func shortened(_ detail: String) -> String? {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let oneLine = trimmed.split(whereSeparator: \.isNewline).joined(separator: " ")
        return oneLine.count > maximumDetailLength ? String(oneLine.prefix(maximumDetailLength - 1)) + "…" : oneLine
    }
}

/// A destination for alerts: native macOS notifications, ntfy, …
public protocol AlertSink: Sendable {
    func deliver(_ alert: HostAlert, includeDetail: Bool) async throws
}

/// Which alerts are delivered.
public struct NotificationPreferences: Sendable, Hashable {
    public var enabled: Bool
    public var kinds: Set<HostAlert.Kind>
    /// Adds a short summary (last message, tool, error) to the body.
    public var includeDetail: Bool

    public init(enabled: Bool, kinds: Set<HostAlert.Kind> = Set(HostAlert.Kind.allCases), includeDetail: Bool = false) {
        self.enabled = enabled
        self.kinds = kinds
        self.includeDetail = includeDetail
    }

    public static let off = NotificationPreferences(enabled: false)
}

/// Turns host activity into alerts.
///
/// Listens to the `NotificationHub` only — it never changes session state.
/// When a session leaves a busy state it waits a moment (so trailing
/// "interrupted" or "process exited" notices land), replays the turn's events
/// and decides with `NotificationRules`.
public actor NotificationService {
    public typealias EventSource = @Sendable (_ sessionId: String, _ fromSeq: Int) async throws -> AsyncStream<SequencedEvent>

    private let log = PilothouseLog("Notifications")
    private let hub: NotificationHub
    private let events: EventSource
    private let settleDelay: Duration
    private var preferences = NotificationPreferences.off
    private var sinks: [any AlertSink] = []
    private var summaries: [String: SessionSummary] = [:]
    /// First sequence number of the current turn per busy session.
    private var turnStart: [String: Int] = [:]
    /// Sessions whose current turn was started from a phone.
    private var phoneTurns: Set<String> = []
    private var listener: Task<Void, Never>?

    public init(hub: NotificationHub, settleDelay: Duration = .milliseconds(1500), events: @escaping EventSource) {
        self.hub = hub
        self.settleDelay = settleDelay
        self.events = events
    }

    /// Starts listening to the hub. Calling it again has no effect.
    public func start() async {
        guard listener == nil else { return }
        let stream = await hub.stream()
        listener = Task { [weak self] in
            for await notification in stream {
                await self?.handle(notification)
            }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    public func configure(_ preferences: NotificationPreferences, sinks: [any AlertSink]) {
        self.preferences = preferences
        self.sinks = sinks
    }

    /// Marks the next turn of `sessionId` as started from a phone; only those
    /// turns produce "task finished" alerts.
    public func noteTurnFromPhone(_ sessionId: String) {
        phoneTurns.insert(sessionId)
    }

    /// Delivers `alert` to every sink if the preferences allow it. Also the
    /// entry point for alerts produced elsewhere (e.g. `.subagentFinished`).
    public func post(_ alert: HostAlert) async {
        guard preferences.enabled, preferences.kinds.contains(alert.kind) else { return }
        let includeDetail = preferences.includeDetail
        for sink in sinks {
            do {
                try await sink.deliver(alert, includeDetail: includeDetail)
            } catch {
                log.error("Could not deliver a \(alert.kind.rawValue) notification: \(error)")
            }
        }
    }

    // MARK: Hub

    func handle(_ notification: HostNotification) async {
        switch notification {
        case .sessionStarted(let summary), .sessionUpdated(let summary):
            let previous = summaries[summary.id]
            summaries[summary.id] = summary
            let wasBusy = previous?.state.isBusy ?? false
            if summary.state.isBusy, !wasBusy {
                turnStart[summary.id] = (previous?.lastSeq).map { $0 + 1 } ?? max(1, summary.lastSeq)
            } else if !summary.state.isBusy, wasBusy, let fromSeq = turnStart.removeValue(forKey: summary.id) {
                let id = summary.id
                Task { [settleDelay] in
                    try? await Task.sleep(for: settleDelay)
                    await self.turnEnded(id, fromSeq: fromSeq)
                }
            }
        case .permissionRequest(let request):
            await post(HostAlert(
                kind: .permissionRequested,
                sessionId: request.sessionId,
                folderName: summaries[request.sessionId]?.folderName ?? Self.folderName(of: request.cwd),
                detail: request.tool
            ))
        case .sessionEnded(let ended) where ended.reason == .processFailed:
            await post(HostAlert(
                kind: .sessionFailed,
                sessionId: ended.sessionId,
                folderName: summaries[ended.sessionId]?.folderName ?? "~",
                detail: ended.message
            ))
        case .sessionDeleted(let id):
            summaries.removeValue(forKey: id)
            turnStart.removeValue(forKey: id)
            phoneTurns.remove(id)
        default:
            break
        }
    }

    private func turnEnded(_ id: String, fromSeq: Int) async {
        let fromPhone = phoneTurns.remove(id) != nil
        guard preferences.enabled, let summary = summaries[id], summary.state != .closed else { return }
        let turnEvents: [SessionEvent]
        if summary.lastSeq >= fromSeq, let stream = try? await events(id, fromSeq) {
            turnEvents = await Self.collect(stream, through: summary.lastSeq, timeout: .seconds(3))
        } else {
            turnEvents = []
        }
        guard let alert = NotificationRules.alert(for: turnEvents, session: summary, fromPhone: fromPhone) else { return }
        await post(alert)
    }

    /// Persisted events of the main conversation up to and including `target`,
    /// or what arrived before `timeout`. Sub-agent threads are left out: their
    /// errors and interruptions are not the turn's (they alert as `.subagentFinished`).
    static func collect(_ stream: AsyncStream<SequencedEvent>, through target: Int, timeout: Duration) async -> [SessionEvent] {
        let collected = Mutex<[SessionEvent]>([])
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in stream where !event.ephemeral {
                    if event.thread == nil {
                        collected.withLock { $0.append(event.event) }
                    }
                    if event.seq >= target { break }
                }
            }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
        return collected.withLock { $0 }
    }

    static func folderName(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? "~" : name
    }
}

/// How the events of a finished turn map to an alert.
public enum NotificationRules {
    /// Notice kinds that mean the CLI failed rather than the turn.
    static let failureNotices: Set<String> = ["processExited", "launchFailed", "loginRequired"]

    /// - Returns: `nil` for interrupted turns, turns without a result, and
    ///   successful turns that were not started from a phone.
    public static func alert(for events: [SessionEvent], session: SessionSummary, fromPhone: Bool) -> HostAlert? {
        var result: SessionEvent.TurnResult?
        var lastAssistantText: String?
        var failure: String?
        for event in events {
            switch event {
            case .systemNotice(let notice) where notice.kind == "interrupted":
                return nil
            case .systemNotice(let notice) where notice.level == .error || failureNotices.contains(notice.kind):
                failure = failure ?? notice.text
            case .result(let turn):
                result = turn
            case .assistantMessage(let message) where !message.text.isEmpty:
                lastAssistantText = message.text
            default:
                break
            }
        }
        if let result, result.isError, failure == nil {
            failure = result.text ?? result.subtype
        }
        if let failure {
            return HostAlert(kind: .sessionFailed, sessionId: session.id, folderName: session.folderName, detail: failure)
        }
        guard result != nil, fromPhone else { return nil }
        return HostAlert(
            kind: .turnFinished, sessionId: session.id, folderName: session.folderName,
            detail: lastAssistantText ?? result?.text
        )
    }
}
