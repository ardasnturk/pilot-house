import XCTest

/// End-to-end UI flows on the demo Mac (prompt §8): pairing screen, new
/// session, sending a message, tool cards, permission approval/denial,
/// interruption and reconnection.
final class PilothouseUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingOffersPairingAndDemo() throws {
        let app = XCUIApplication.pilothouse(demo: false)
        app.launch()

        let pair = app.buttons["pairButton"]
        XCTAssertTrue(pair.waitForExistence(timeout: 10))
        pair.tap()

        // The simulator has no camera scanner, so the paste step is shown.
        let field = app.element("pairingLinkField")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("https://example.com/not-a-pairing-link")
        app.buttons["confirmPairButton"].tap()
        XCTAssertTrue(app.staticTexts["Pairing failed"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()

        app.buttons["demoButton"].tap()
        XCTAssertTrue(app.element("connectionStatus").waitForExistence(timeout: 15))
        XCTAssertTrue(app.element("session-Fix the flaky login test").waitForExistence(timeout: 15))
    }

    @MainActor
    func testSeededSessionShowsToolCardsAndDiff() throws {
        let app = XCUIApplication.pilothouse(demo: true)
        app.launch()

        let session = app.element("session-Fix the flaky login test")
        XCTAssertTrue(session.waitForExistence(timeout: 15))
        session.tap()

        let edit = app.element("tool-Edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        XCTAssertTrue(app.element("tool-Read").exists)
        XCTAssertTrue(app.element("tool-Bash").exists)
        XCTAssertTrue(app.element("userMessage").exists)
        XCTAssertTrue(app.element("assistantMessage").exists)

        edit.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["+    let clock: any Clock<Duration>"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNewSessionMessageAndPermissionApproval() throws {
        let app = XCUIApplication.pilothouse(demo: true)
        app.launch()
        try startSession(in: app, path: ["Developer", "weather-app"])

        send("Fix the flaky test", in: app)

        // Edit needs approval, then Bash: allow once, then always for `swift`.
        let allow = app.buttons["allowButton"]
        XCTAssertTrue(allow.waitForExistence(timeout: 30))
        allow.tap()
        let always = app.buttons["alwaysAllowButton"]
        XCTAssertTrue(always.waitForExistence(timeout: 30))
        always.tap()

        XCTAssertTrue(app.element("tool-Bash").waitForExistence(timeout: 30))
        XCTAssertTrue(app.element("tool-TodoWrite").exists)
        XCTAssertTrue(app.buttons["stopButton"].waitForNonExistence(timeout: 60), "The turn should finish")
    }

    @MainActor
    func testDenyingPermissionStopsTheAction() throws {
        let app = XCUIApplication.pilothouse(demo: true)
        app.launch()
        try startSession(in: app, path: ["Developer", "scripts"])
        send("Clean up the scripts", in: app)

        let deny = app.buttons["denyButton"]
        XCTAssertTrue(deny.waitForExistence(timeout: 30))
        deny.tap()
        XCTAssertTrue(app.staticTexts["Denied"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["stopButton"].waitForNonExistence(timeout: 30))
    }

    @MainActor
    func testStopInterruptsTheTurn() throws {
        let app = XCUIApplication.pilothouse(demo: true, pace: 0.5)
        app.launch()
        try startSession(in: app, path: ["Developer", "portfolio-site"])
        send("Add a footer", in: app)

        let stop = app.buttons["stopButton"]
        XCTAssertTrue(stop.waitForExistence(timeout: 20))
        stop.tap()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Stopped"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testReconnectsAfterNetworkDrop() throws {
        let app = XCUIApplication.pilothouse(demo: true)
        app.launch()
        XCTAssertTrue(app.element("session-Fix the flaky login test").waitForExistence(timeout: 15))

        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        let drop = app.buttons["simulateNetworkDrop"]
        XCTAssertTrue(app.scrollToElement(drop))
        drop.tap()
        app.buttons["Done"].tap()

        // The client reconnects by itself and the Mac's sessions are still there.
        let newChat = app.buttons["newChatButton"]
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: newChat)
        waitForExpectations(timeout: 20)
        try startSession(in: app, path: ["Documents"])
        send("Summarise my notes", in: app)
        XCTAssertTrue(app.buttons["allowButton"].waitForExistence(timeout: 30) || app.element("tool-Glob").exists)
    }

    @MainActor
    func testCreatesAFolderAndStartsThere() throws {
        let app = XCUIApplication.pilothouse(demo: true)
        app.launch()
        let newChat = app.buttons["newChatButton"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 20))
        newChat.tap()
        let developer = app.element("folder-Developer")
        XCTAssertTrue(developer.waitForExistence(timeout: 10))
        developer.tap()

        let newFolder = app.buttons["newFolderButton"]
        XCTAssertTrue(newFolder.waitForExistence(timeout: 10))
        newFolder.tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("side-project")
        app.alerts.buttons["Create"].tap()

        // The new folder opens, so the session starts inside it.
        let start = app.buttons["startSessionButton"]
        let inNewFolder = NSPredicate(format: "label CONTAINS 'side-project'")
        expectation(for: inNewFolder, evaluatedWith: start)
        waitForExpectations(timeout: 10)
        start.tap()
        XCTAssertTrue(app.element("composerField").waitForExistence(timeout: 15))
    }

    @MainActor
    func testDelegatedSubAgentOpensInItsOwnWindow() throws {
        let app = XCUIApplication.pilothouse(demo: true)
        app.launch()
        let newChat = app.buttons["newChatButton"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 20))
        newChat.tap()
        XCTAssertTrue(app.element("agentPicker").waitForExistence(timeout: 10), "The demo Mac offers several agents")
        app.buttons["Cancel"].tap()

        try startSession(in: app, path: ["Developer", "weather-app"])
        send("Ask Codex for a second opinion", in: app)

        let card = app.element("tool-mcp__pilothouse__delegate_to_agent")
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["stopButton"].waitForNonExistence(timeout: 60), "The turn should finish")
        card.buttons.firstMatch.tap()
        let open = app.buttons["openSubAgent"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()

        // The sheet shows Codex's own steps and its answer.
        XCTAssertTrue(app.element("tool-Bash").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Inject a Clock'")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
    }

    @MainActor
    func testWeeklySummaryAndLimits() throws {
        let app = XCUIApplication.pilothouse(demo: true)
        app.launch()
        let card = app.element("thisWeekCard")
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()

        XCTAssertTrue(app.element("weeklyNarrative").waitForExistence(timeout: 15))
        XCTAssertTrue(app.element("project-weather-app").waitForExistence(timeout: 5))

        app.segmentedControls["insightsTabs"].buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.element("limits-claude").waitForExistence(timeout: 10))
        XCTAssertTrue(app.element("limits-codex").exists)
        app.buttons["Done"].tap()
    }

    @MainActor
    func testSlashOpensSearchableSkillsAndCommands() throws {
        let app = XCUIApplication.pilothouse(demo: true)
        app.launch()
        try startSession(in: app, path: ["Developer", "weather-app"])
        let composer = app.element("composerField")
        composer.tap()
        composer.typeText("/")

        // Skills and commands are listed separately; the filter shows one kind.
        XCTAssertTrue(app.element("command-changelog").waitForExistence(timeout: 10))
        let filter = app.segmentedControls["commandFilter"]
        // The list is lazy and the sheet starts at half height: check the first rows only.
        filter.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(app.element("command-compact").waitForExistence(timeout: 5))
        XCTAssertFalse(app.element("command-changelog").exists, "Commands only")
        filter.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.element("command-changelog").waitForExistence(timeout: 5))
        XCTAssertFalse(app.element("command-compact").exists, "Skills only")

        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("figma")
        let figma = app.element("command-figma:figma-use")
        XCTAssertTrue(figma.waitForExistence(timeout: 5))
        figma.tap()

        let inserted = NSPredicate(format: "value BEGINSWITH '/figma:figma-use'")
        expectation(for: inserted, evaluatedWith: composer)
        waitForExpectations(timeout: 5)
    }

    // MARK: Helpers

    @MainActor
    private func startSession(in app: XCUIApplication, path: [String]) throws {
        let newChat = app.buttons["newChatButton"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 20))
        newChat.tap()
        for folder in path {
            let row = app.element("folder-\(folder)")
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Folder \(folder) not listed")
            row.tap()
        }
        let start = app.buttons["startSessionButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.element("composerField").waitForExistence(timeout: 15))
    }

    @MainActor
    private func send(_ text: String, in app: XCUIApplication) {
        let composer = app.element("composerField")
        composer.tap()
        composer.typeText(text)
        app.buttons["sendButton"].tap()
    }
}
