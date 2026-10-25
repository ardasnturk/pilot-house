import AppKit
import UserNotifications

/// Owns the `AppController` so it starts at launch (not when the menu first
/// opens) and gets a chance to stop every Claude process before quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
    private let notificationDelegate = NotificationCenterDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a pipe whose reader died must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        Task { await controller.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = self.controller
        Task {
            await controller.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Already released in shutdown(); kept explicit as a safety net (prompt §4.3).
        controller.sleepAssertion.release()
    }
}
