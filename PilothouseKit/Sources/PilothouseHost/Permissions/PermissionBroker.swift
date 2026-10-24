import Foundation
import PilothouseKit

/// Fans host notifications out to every connected phone (and the Mac UI).
public actor NotificationHub {
    private var subscribers: [UUID: AsyncStream<HostNotification>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<HostNotification> {
        let (stream, continuation) = AsyncStream.makeStream(of: HostNotification.self, bufferingPolicy: .unbounded)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        return stream
    }

    public func post(_ notification: HostNotification) {
        for continuation in subscribers.values {
            continuation.yield(notification)
        }
    }

    public var subscriberCount: Int { subscribers.count }

    private func remove(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}

/// Holds permission requests until a phone answers or they time out
/// (default 10 minutes → deny; prompt §4.4).
public actor PermissionBroker {
    public enum Decision: Sendable, Equatable {
        case allow(remember: Bool)
        case deny
        case timedOut
        /// The turn was interrupted or the session closed.
        case cancelled
    }

    public let timeout: Duration
    private let hub: NotificationHub
    private var pending: [String: (request: PermissionRequest, continuation: CheckedContinuation<Decision, Never>)] = [:]

    public init(hub: NotificationHub, timeout: Duration = .seconds(600)) {
        self.hub = hub
        self.timeout = timeout
    }

    /// Broadcasts a request and suspends until it is decided.
    public func request(sessionId: String, tool: String, input: JSONValue, cwd: String) async -> (PermissionRequest, Decision) {
        let now = Date()
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let request = PermissionRequest(
            id: UUID().uuidString.lowercased(),
            sessionId: sessionId,
            tool: tool,
            input: input.truncatingStrings(maxLength: StreamJSONNormalizer.maximumTextLength),
            cwd: cwd,
            createdAt: now,
            expiresAt: now.addingTimeInterval(seconds),
            rememberKey: PermissionRequest.rememberKey(tool: tool, input: input)
        )
        let timeout = self.timeout
        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<Decision, Never>) in
            pending[request.id] = (request, continuation)
            Task { await hub.post(.permissionRequest(request)) }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resolve(request.id, with: .timedOut)
            }
        }
        return (request, decision)
    }

    /// Applies a phone's answer. Throws `notFound` for unknown or expired requests.
    public func respond(_ response: PermissionResponse) throws {
        guard pending[response.requestId] != nil else {
            throw ErrorPayload(code: .notFound, message: "This request was already answered or has expired.")
        }
        resolve(response.requestId, with: response.allow ? .allow(remember: response.remember ?? false) : .deny)
    }

    /// Cancels every open request of a session (interrupt / close).
    public func cancelAll(sessionId: String) {
        for (id, entry) in pending where entry.request.sessionId == sessionId {
            resolve(id, with: .cancelled)
        }
    }

    public var pendingRequests: [PermissionRequest] {
        pending.values.map(\.request).sorted { $0.createdAt < $1.createdAt }
    }

    private func resolve(_ id: String, with decision: Decision) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(returning: decision)
        let outcome: SessionEvent.PermissionDecision.Outcome = switch decision {
        case .allow(let remember): remember ? .allowedForSession : .allowed
        case .deny: .denied
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        }
        let resolved = PermissionResolved(requestId: id, sessionId: entry.request.sessionId, outcome: outcome)
        Task { await hub.post(.permissionResolved(resolved)) }
    }
}
