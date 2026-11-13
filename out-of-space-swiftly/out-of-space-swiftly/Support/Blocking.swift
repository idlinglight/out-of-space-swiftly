import Foundation
import Synchronization

/// Calls that can block for a long time: anything that asks a volume, which may be slow, asleep, a network
/// mount that went away, or behind a privacy check (docs/SCANNING.md, ADR-0006).
///
/// Such a call runs on a thread of its own. Not on the main actor, which would freeze the app. Not on
/// Swift's cooperative pool, which has one thread per core and no spare for one that is stuck. And not on
/// GCD's global queues, which get no further thread while as many threads as there are cores are running,
/// so that in a busy process the call would start late and a timeout there would fire late. Timeouts run on
/// a serial queue of their own for the same reason.
///
/// Both run at user-initiated priority, since someone is waiting for the answer; busy threads of other work
/// then delay them by hundredths of a second (docs/SCANNING.md, section 1).
nonisolated enum Blocking {
    /// Runs `work` on a thread of its own and returns what it returns, or nil when it takes longer than
    /// `timeout`. A call that is late finishes on its own; its result is dropped.
    ///
    /// The caller is resumed on its own actor: from the main actor, nothing here waits for a shared pool.
    static func run<Value: Sendable>(
        _ name: String, timeout: Duration, _ work: @escaping @Sendable () -> Value
    ) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let handover = Handover(continuation)
            startThread(name) { handover.resume(returning: work()) }
            after(timeout) { handover.resume(returning: nil) }
        }
    }

    /// Runs `work` on a thread of its own and returns what it returns, however long that takes. For an
    /// answer that nothing else is held up for: it is used when it comes.
    static func run<Value: Sendable>(_ name: String, _ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            startThread(name) { continuation.resume(returning: work()) }
        }
    }

    /// Starts a thread for one blocking call.
    static func startThread(_ name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Runs `body` once `timeout` has passed.
    static func after(_ timeout: Duration, _ body: @escaping @Sendable () -> Void) {
        timeouts.asyncAfter(deadline: .now() + timeout / .seconds(1), execute: body)
    }

    private static let timeouts = DispatchQueue(
        label: "at.idling.out-of-space-swiftly.timeouts", qos: .userInitiated
    )

    /// Resumes a continuation with the first answer it is given; later ones are dropped.
    private final class Handover<Value: Sendable>: Sendable {
        private let continuation: Mutex<CheckedContinuation<Value?, Never>?>

        init(_ continuation: CheckedContinuation<Value?, Never>) {
            self.continuation = Mutex(continuation)
        }

        func resume(returning value: Value?) {
            let waiting = continuation.withLock { continuation in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(returning: value)
        }
    }
}
