import XCTest

/// Shared helpers. The app runs against the in-process demo Mac
/// (`MockMacServer` = `DemoHostService`) over the real encrypted protocol.
extension XCUIApplication {
    /// Launches with in-memory storage and fast, deterministic demo pacing.
    @MainActor
    static func pilothouse(demo: Bool, pace: Double = 0.02, language: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-DemoPace", String(pace)]
        if demo { app.launchArguments.append("-DemoMode") }
        let language = language ?? ProcessInfo.processInfo.environment["SCREENSHOT_LANGUAGE"] ?? "en"
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", Self.locale(for: language)]
        return app
    }

    private static func locale(for language: String) -> String {
        switch language {
        case "tr": "tr_TR"
        case "de": "de_DE"
        default: "en_US"
        }
    }

    /// Any element with the given accessibility identifier.
    @MainActor
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier].firstMatch
    }

    /// On iPhone the split view collapses; go back to the session list if needed.
    @MainActor
    func returnToSessionList() {
        let newChat = buttons["newChatButton"]
        guard !newChat.isHittable else { return }
        let back = navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
    }
}
