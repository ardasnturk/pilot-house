import Foundation
import Synchronization

/// An unbounded multi-producer, single-consumer async FIFO.
///
/// `pop()` suspends until an element arrives, the queue is finished
/// (throws `QueueClosedError`) or the calling task is cancelled
/// (throws `CancellationError`).
public actor AsyncQueue<Element: Sendable> {
    public struct QueueClosedError: Error, Sendable {}

    private var buffer: [Element] = []
    private var waiters: [UUID: CheckedContinuation<Element, Error>] = [:]
    private var waiterOrder: [UUID] = []
    private var finishedError: (any Error)?

    public init() {}

    public func push(_ element: Element) {
        guard finishedError == nil else { return }
        if let id = waiterOrder.first, let waiter = waiters.removeValue(forKey: id) {
            waiterOrder.removeFirst()
            waiter.resume(returning: element)
        } else {
            buffer.append(element)
        }
    }

    public func pop() async throws -> Element {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if let finishedError { throw finishedError }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Element, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                    waiterOrder.append(id)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Ends the queue. Buffered elements are still delivered; afterwards `pop()`
    /// throws `error` (default `QueueClosedError`).
    public func finish(throwing error: (any Error)? = nil) {
        guard finishedError == nil else { return }
        let failure = error ?? QueueClosedError()
        finishedError = failure
        for id in waiterOrder {
            waiters[id]?.resume(throwing: failure)
        }
        waiters.removeAll()
        waiterOrder.removeAll()
    }

    public var isFinished: Bool { finishedError != nil }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        waiter.resume(throwing: CancellationError())
    }
}

/// Error thrown by `withTimeout` when the deadline passes first.
public struct TimeoutError: Error, Sendable, Equatable {
    public init() {}
}

/// Resumes a continuation at most once, from any thread.
public final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<Value, Error>?>(nil)

    public init() {}

    public func install(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation.withLock { $0 = continuation }
    }

    /// Returns `true` if this call resumed the continuation.
    @discardableResult
    public func resume(with result: Result<Value, Error>) -> Bool {
        guard let continuation = continuation.withLock({ stored -> CheckedContinuation<Value, Error>? in
            defer { stored = nil }
            return stored
        }) else { return false }
        continuation.resume(with: result)
        return true
    }
}

/// Runs `operation`, throwing `TimeoutError` if it does not finish within
/// `seconds`.
///
/// Unlike a task-group race this returns as soon as the deadline passes even if
/// `operation` ignores cancellation (e.g. a pending socket read): the operation
/// is cancelled and left to finish in the background, and `onTimeout` runs so
/// the caller can close the resource the operation is blocked on.
public func withTimeout<T: Sendable>(
    seconds: Double,
    onTimeout: (@Sendable () async -> Void)? = nil,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let once = ResumeOnce<T>()
    let worker = Mutex<Task<Void, Never>?>(nil)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            once.install(continuation)
            let operationTask = Task {
                do {
                    once.resume(with: .success(try await operation()))
                } catch {
                    once.resume(with: .failure(error))
                }
            }
            worker.withLock { $0 = operationTask }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.resume(with: .failure(TimeoutError())) {
                    operationTask.cancel()
                    await onTimeout?()
                }
            }
        }
    } onCancel: {
        if once.resume(with: .failure(CancellationError())) {
            worker.withLock { $0?.cancel() }
        }
    }
}
