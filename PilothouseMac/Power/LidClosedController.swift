import AppKit
import Foundation
import IOKit.ps
import Observation
import PilothouseKit
import ServiceManagement

/// Optional "stay awake with the lid closed" mode (prompt §4.3).
///
/// `pmset -a disablesleep 1` needs root, so it goes through the privileged
/// helper registered with `SMAppService.daemon`. The helper reverts the value
/// itself when the app disconnects, so a crash never leaves the Mac sleepless.
@MainActor
@Observable
final class LidClosedController {
    enum State: Equatable {
        case off
        /// The user must allow the helper in System Settings → Login Items.
        case needsApproval
        case active
        /// Enabled in settings but paused because the Mac runs on battery.
        case pausedOnBattery
        case failed(String)
    }

    private(set) var state: State = .off
    private(set) var isOnBattery = false

    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var batteryTask: Task<Void, Never>?
    @ObservationIgnored private var wantsEnabled = false
    @ObservationIgnored private var pauseOnBattery = true
    @ObservationIgnored private let service = SMAppService.daemon(plistName: HelperConstants.plistName)

    var isEffectivelyActive: Bool { state == .active }

    /// Applies the current settings. Safe to call repeatedly.
    func apply(enabled: Bool, pauseOnBattery: Bool) async {
        wantsEnabled = enabled
        self.pauseOnBattery = pauseOnBattery
        startBatteryMonitoring()
        isOnBattery = Self.readIsOnBattery()
        await reconcile()
    }

    /// Turns the mode off before quitting.
    func restore() async {
        wantsEnabled = false
        batteryTask?.cancel()
        if state == .active || state == .pausedOnBattery {
            _ = await setSleepDisabled(false)
        }
        connection?.invalidate()
        connection = nil
        state = .off
    }

    /// Opens System Settings → General → Login Items for helper approval.
    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func reconcile() async {
        guard wantsEnabled else {
            if state == .active { _ = await setSleepDisabled(false) }
            state = .off
            return
        }
        guard await registerHelperIfNeeded() else { return }
        if pauseOnBattery && isOnBattery {
            if state == .active { _ = await setSleepDisabled(false) }
            state = .pausedOnBattery
            return
        }
        let (ok, message) = await setSleepDisabled(true)
        state = ok ? .active : .failed(message ?? String(localized: "The helper could not change the sleep setting."))
    }

    private func registerHelperIfNeeded() async -> Bool {
        switch service.status {
        case .enabled:
            return true
        case .requiresApproval:
            state = .needsApproval
            return false
        case .notRegistered, .notFound:
            do {
                try service.register()
            } catch {
                if service.status == .requiresApproval {
                    state = .needsApproval
                } else {
                    state = .failed(error.localizedDescription)
                }
                return false
            }
            if service.status == .requiresApproval {
                state = .needsApproval
                return false
            }
            return service.status == .enabled
        @unknown default:
            state = .failed(String(localized: "Unknown helper status."))
            return false
        }
    }

    private func helperConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PilothouseHelperProtocol.self)
        connection.setCodeSigningRequirement(HelperConstants.helperRequirement)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func setSleepDisabled(_ disabled: Bool) async -> (Bool, String?) {
        let connection = helperConnection()
        return await withCheckedContinuation { continuation in
            let once = ResumeOnceBox(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume((false, error.localizedDescription))
            }
            guard let helper = proxy as? PilothouseHelperProtocol else {
                once.resume((false, String(localized: "The helper is not available.")))
                return
            }
            helper.setSleepDisabled(disabled) { ok, message in
                once.resume((ok, message))
            }
        }
    }

    // MARK: Battery

    private func startBatteryMonitoring() {
        guard batteryTask == nil else { return }
        batteryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                let onBattery = Self.readIsOnBattery()
                if onBattery != self.isOnBattery {
                    self.isOnBattery = onBattery
                    await self.reconcile()
                }
            }
        }
    }

    static func readIsOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

/// Resumes a continuation once, from whichever XPC callback fires first.
private final class ResumeOnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Bool, String?), Never>?

    init(_ continuation: CheckedContinuation<(Bool, String?), Never>) {
        self.continuation = continuation
    }

    func resume(_ value: (Bool, String?)) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
