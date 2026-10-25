import XCTest

/// Shared helpers. The app runs against the in-process demo Mac
/// (`MockMacServer` = `DemoHostService`) over the real encrypted protocol.
extension XCUIApplication {
    /// Launches with in-memory storage and fast, deterministic demo pacing.
    @MainActor
    static func remoteCode(demo: Bool, pace: Double = 0.02, language: String? = nil) -> XCUIApplication {
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

    /// Scrolls the frontmost list or form until `element` is on screen.
    /// Lists are lazy: rows below the fold are not in the hierarchy yet.
    @MainActor
    func scrollToElement(_ element: XCUIElement, maxSwipes: Int = 8) -> Bool {
        let list = collectionViews.firstMatch.exists ? collectionViews.firstMatch : tables.firstMatch
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return true }
            list.swipeUp()
        }
        return element.exists && element.isHittable
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
