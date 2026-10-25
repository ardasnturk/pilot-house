import XCTest

/// Captures App Store screenshots from the demo Mac (prompt §9).
///
/// Run through `scripts/screenshots.sh`, which loops over devices
/// (iPhone, iPad), appearances (light, dark) and languages (en, tr, de) and
/// extracts the attachments from the result bundle. Content is fictional.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testCaptureScreenshots() throws {
        let app = XCUIApplication.remoteCode(demo: true, pace: 0.15)
        app.launch()

        let session = app.element("session-\(Self.seedTitle)")
        _ = app.element("connectionStatus").waitForExistence(timeout: 20)
        _ = session.waitForExistence(timeout: 20)
        snapshot("01-Sessions")

        session.tap()
        let edit = app.element("tool-Edit")
        if edit.waitForExistence(timeout: 10) {
            snapshot("02-Chat")
            edit.buttons.firstMatch.tap()
            sleep(1)
            snapshot("03-Diff")
        }

        app.returnToSessionList()
        let newChat = app.buttons["newChatButton"]
        guard newChat.waitForExistence(timeout: 10) else { return }
        newChat.tap()
        let developer = app.element("folder-Developer")
        if developer.waitForExistence(timeout: 10) {
            developer.tap()
            _ = app.element("folder-weather-app").waitForExistence(timeout: 10)
            snapshot("04-NewChat")
            app.element("folder-weather-app").tap()
        }
        let start = app.buttons["startSessionButton"]
        guard start.waitForExistence(timeout: 10) else { return }
        start.tap()
        let composer = app.element("composerField")
        guard composer.waitForExistence(timeout: 15) else { return }
        composer.tap()
        composer.typeText(Self.prompt)
        app.buttons["sendButton"].tap()
        if app.buttons["allowButton"].waitForExistence(timeout: 40) {
            sleep(1)
            snapshot("05-Permission")
        }
    }

    /// Title of the seeded demo session in the screenshot language.
    static var seedTitle: String {
        switch ProcessInfo.processInfo.environment["SCREENSHOT_LANGUAGE"] {
        case "tr": "Kararsız giriş testini düzelt"
        case "de": "Wackeligen Login-Test reparieren"
        default: "Fix the flaky login test"
        }
    }

    static var prompt: String {
        switch ProcessInfo.processInfo.environment["SCREENSHOT_LANGUAGE"] {
        case "tr": "Giriş ekranındaki kararsız testi düzelt"
        case "de": "Repariere den wackeligen Login-Test"
        default: "Fix the flaky login test"
        }
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
