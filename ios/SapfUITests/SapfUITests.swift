//    SAPF - Sound As Pure Form
//    UI tests for the iOS front end. Set SAPF_SCREENSHOT_DIR in the scheme's test
//    environment to also save screenshots there.

import XCTest

final class SapfUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-currentDocument", "Scratch.sapf"]
        app.launch()
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

    /// Writes code into a fresh document so tests don't depend on what's in Scratch.
    private func newDocument(with code: String) -> XCUIElement {
        app.buttons["Documents"].tap()
        app.buttons["New Document"].tap()
        let editor = app.textViews.firstMatch
        editor.tap()
        editor.typeText(code)
        return editor
    }

    func testTapWordShowsHelp() {
        let editor = newDocument(with: "440 0 sinosc .2 * play")
        // Dismiss the keyboard so the tap lands on text, then tap near the start of "sinosc".
        app.buttons["Hide keyboard"].firstMatch.tap()
        let line = editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 39 + 8.4 * 8, dy: 22) /* gutter + padding + "440 0 si" */)
        line.tap()
        let tooltip = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'sine'")).firstMatch
        XCTAssertTrue(tooltip.waitForExistence(timeout: 3), "help tooltip for sinosc")
        screenshot("tooltip")
    }

    func testGutterButtonRunsItsBlock() {
        _ = newDocument(with: "1 2 +\n\n3 4 *")
        app.buttons["Hide keyboard"].firstMatch.tap()
        let runButtons = app.buttons.matching(identifier: "Run block")
        XCTAssertEqual(runButtons.count, 2)
        runButtons.element(boundBy: 1).tap()
        if app.buttons["Console"].exists { app.buttons["Console"].tap() }
        let console = app.textViews["Console"]
        let predicate = NSPredicate(format: "value CONTAINS 'sapf> 3 4 *'")
        expectation(for: predicate, evaluatedWith: console)
        waitForExpectations(timeout: 3)
        XCTAssertFalse((console.value as? String ?? "").contains("sapf> 1 2 +"), "only the tapped block ran")
        screenshot("gutter")
    }

    func testRunShowsOutputAndVisuals() {
        _ = newDocument(with: "300 1000 xmousex 0 sinosc .2 * play\n1 2 +")
        app.buttons["Hide keyboard"].firstMatch.tap()
        app.textViews.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 22)).tap()
        app.buttons["Run"].firstMatch.tap()
        // On a phone the panels collapse to a small waveform while typing.
        screenshot("running-keyboard")
        if app.buttons["Hide keyboard"].isHittable { app.buttons["Hide keyboard"].firstMatch.tap() }

        if app.buttons["Scope"].waitForExistence(timeout: 2) {
            app.buttons["Scope"].tap()
            sleep(1)
            screenshot("scope")
            app.buttons["Spectrum"].tap()
            sleep(1)
            screenshot("spectrum")
            app.buttons["Sonogram"].tap()
            sleep(2)
            screenshot("sonogram")
            app.buttons["Console"].tap()
        } else {
            sleep(2)
        }
        screenshot("console")
        let console = app.textViews["Console"]
        XCTAssertTrue((console.value as? String ?? "").contains("3"), "stack printed")
        app.buttons["Stop"].firstMatch.tap()
    }

    /// Plays something busy and captures every layout, for checking screen size handling by eye.
    func testLayouts() {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        _ = newDocument(with: "((.4 0 lfsaw) 2 * ([8 7.23] 0 lfsaw) .25 * 9.667 + + exp2) 0 sinosc .04 * .2 0 4 combn play")
        app.buttons["Run"].firstMatch.tap()
        if app.buttons["Hide keyboard"].isHittable { app.buttons["Hide keyboard"].firstMatch.tap() }
        if app.buttons["Scope"].exists { app.buttons["Scope"].tap() }
        sleep(2)
        screenshot("\(device)-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        screenshot("\(device)-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["Stop"].firstMatch.tap()
    }
}
