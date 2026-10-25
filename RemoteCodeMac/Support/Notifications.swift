import Foundation
import RemoteCodeHost
import UserNotifications

/// Localised notification text (docs/DECISIONS.md D-095).
enum AlertText {
    /// The one-line headline and the optional detail line.
    static func parts(of alert: HostAlert, includeDetail: Bool) -> (headline: String, detail: String?) {
        let folder = alert.folderName
        let headline = switch alert.kind {
        case .turnFinished: String(localized: "Task finished · \(folder)")
        case .permissionRequested: String(localized: "Approval needed · \(folder)")
        case .sessionFailed: String(localized: "Session failed · \(folder)")
        case .subagentFinished: String(localized: "Sub-agent finished · \(folder)")
        }
        guard includeDetail, let detail = alert.detail else { return (headline, nil) }
        if alert.kind == .permissionRequested {
            return (headline, String(localized: "Claude wants to use \(detail)"))
        }
        return (headline, detail)
    }

    /// ntfy: the app name as title, the headline (and detail) as message.
    @Sendable static func ntfyContent(for alert: HostAlert, includeDetail: Bool) -> AlertContent {
        let (headline, detail) = parts(of: alert, includeDetail: includeDetail)
        return AlertContent(title: "Remote Code", body: AlertContent.body(headline, detail: detail))
    }
}

/// Native notifications through `UNUserNotificationCenter`.
struct MacNotificationSink: AlertSink {
    func deliver(_ alert: HostAlert, includeDetail: Bool) async throws {
        let (headline, detail) = AlertText.parts(of: alert, includeDetail: includeDetail)
        let content = UNMutableNotificationContent()
        content.title = headline
        if let detail = detail.flatMap(AlertContent.shortened) {
            content.body = detail
        }
        content.sound = .default
        content.threadIdentifier = alert.sessionId
        content.userInfo = ["sessionId": alert.sessionId]
        try await deliver(content)
    }

    func deliver(_ content: UNNotificationContent) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Asks once; later calls return the stored answer.
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
}

/// Shows banners even while Remote Code is the active app (e.g. Settings is open).
final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
