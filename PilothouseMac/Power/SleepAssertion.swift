import Foundation
import IOKit.pwr_mgt
import Synchronization

/// Keeps the Mac from idle-sleeping while Pilothouse runs (prompt §4.3).
///
/// Uses `kIOPMAssertionTypePreventUserIdleSystemSleep`: the display may still
/// turn off; only *system* sleep is prevented. The assertion is released in
/// `release()`, in `deinit`, and by the kernel when the process exits.
final class SleepAssertion: Sendable {
    private let assertion = Mutex<IOPMAssertionID?>(nil)

    var isActive: Bool {
        assertion.withLock { $0 != nil }
    }

    @discardableResult
    func acquire() -> Bool {
        assertion.withLock { current in
            if current != nil { return true }
            var identifier = IOPMAssertionID(0)
            let reason = "Pilothouse keeps this Mac awake so your Claude Code sessions stay reachable from your phone." as CFString
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &identifier
            )
            guard result == kIOReturnSuccess else { return false }
            current = identifier
            return true
        }
    }

    func release() {
        assertion.withLock { current in
            if let identifier = current {
                IOPMAssertionRelease(identifier)
            }
            current = nil
        }
    }

    deinit {
        release()
    }
}
