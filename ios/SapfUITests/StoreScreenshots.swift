//    SAPF - Sound As Pure Form
//    App Store screenshots. Skipped unless SAPF_STORE_SCREENSHOTS is set in the test environment
//    (TEST_RUNNER_SAPF_STORE_SCREENSHOTS=1 on the xcodebuild command line). Expects Examples.sapf and
//    Scratch.sapf in the app's Documents to have been replaced with the showcase versions first.

import XCTest

final class StoreScreenshots: XCTestCase {
    var app: XCUIApplication!
    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SAPF_STORE_SCREENSHOTS"] != nil, "store screenshots not requested")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["-currentDocument", "Examples.sapf", "-uiMode", "Dark", "-helpOnTap", "YES"]
        app.launch()
        sleep(2)
        // Reading, so the keyboard and key bar are out of the way.
        if app.navigationBars.buttons["Hide keyboard"].exists { app.navigationBars.buttons["Hide keyboard"].tap() }
        // The startup messages include the simulator's file paths.
        app.buttons["More"].firstMatch.tap()
        app.buttons["Clear Console"].firstMatch.tap()
    }

    private func screenshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SAPF_SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    private func showPanel(_ tab: String) {
        if app.buttons[tab].exists { app.buttons[tab].tap() }
    }

    /// Taps the text at a column of a line, counting lines from the top of the document.
    private func tapText(line: Int, column: Int) {
        let fontSize: CGFloat = isPad ? 16 : 14
        let editor = app.textViews.firstMatch
        let point = CGVector(dx: 39 + (CGFloat(column) + 0.5) * fontSize * 0.6, dy: 12 + (CGFloat(line) + 0.5) * fontSize * 1.215)
        editor.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
    }

    func testStoreScreenshots() {
        // 1. Harmonic clouds playing, with its spectrogram.
        app.buttons.matching(identifier: "Run block").firstMatch.tap()
        showPanel("Sonogram")
        sleep(12)
        screenshot("1-playing")

        // 2. Help for a word, on top of the waveform.
        showPanel("Scope")
        tapText(line: 1, column: 12) // xrand
        sleep(2)
        screenshot("2-help")
        app.navigationBars.buttons["Stop"].tap()

        // 3. A plot of the top of the stack.
        app.buttons["Documents"].firstMatch.tap()
        app.buttons["Scratch"].firstMatch.tap()
        sleep(1)
        app.buttons.matching(identifier: "Run block").firstMatch.tap()
        sleep(1)
        app.buttons["More"].firstMatch.tap()
        app.buttons["Plot Top of Stack"].tap()
        sleep(2)
        screenshot("3-plot")

        // 4. Every function, with its help.
        app.buttons["More"].firstMatch.tap()
        app.buttons["List All Functions"].firstMatch.tap()
        XCTAssertTrue(app.textViews["All Functions"].waitForExistence(timeout: 5))
        // Scroll to the oscillators by finding them, then put the find bar away.
        app.navigationBars["All Functions"].buttons["Find"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        sleep(1)
        // A fresh simulator's keyboard first shows a tip about sliding to type.
        if app.buttons["Continue"].exists { app.buttons["Continue"].tap(); sleep(1) }
        app.typeText("oscillator unit generators")
        sleep(1)
        app.buttons["find.doneButton"].tap()
        sleep(1)
        // Finding leaves the heading at the bottom; drag it up near the top, without momentum.
        let list = app.textViews["All Functions"]
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        sleep(1)
        screenshot("4-functions")
        app.buttons["Done"].firstMatch.tap()
    }
}
