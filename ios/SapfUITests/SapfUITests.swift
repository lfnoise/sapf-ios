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
        app.buttons["Run block"].firstMatch.tap()
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

    func testReadingModeKeepsKeyboardAway() {
        _ = newDocument(with: "440 0 sinosc .2 * play")
        app.buttons["Hide keyboard"].firstMatch.tap()
        // Tapping text while reading shows help but doesn't bring the keyboard back.
        app.textViews.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 39 + 8.4 * 8, dy: 22)).tap()
        sleep(1)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "no keyboard while reading")
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2), "Edit brings up the keyboard")
        // The same toolbar button now hides it.
        app.navigationBars.buttons["Hide keyboard"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 2), "back to reading")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testPanelStaysAboveKeyboardAfterRotating() {
        _ = newDocument(with: "440 0 sinosc .2 * play")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        screenshot("keyboard-after-rotation")
        let accessory = app.buttons["Evaluate"].firstMatch // on the key bar
        XCTAssertTrue(accessory.exists)
        // With the on-screen keyboard the panel shrinks to a waveform; with a hardware keyboard
        // (only the key bar showing) the whole panel stays, with the console on top.
        let panel = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Waveform'")).allElementsBoundByIndex
            + app.textViews.matching(identifier: "Console").allElementsBoundByIndex
        XCTAssertFalse(panel.isEmpty, "the bottom panel is showing")
        for element in panel {
            XCTAssertLessThanOrEqual(element.frame.maxY, accessory.frame.minY, "\(element.label) is above the keyboard's accessory bar")
        }
    }

    private func plotTopOfStack() {
        app.buttons["More"].firstMatch.tap()
        app.buttons["Plot Top of Stack"].tap()
    }

    private func waveform() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Waveform'")).firstMatch
    }

    func testPlotTopOfStack() {
        _ = newDocument(with: "[1 4 9 16 25 16 9 4 1]\n\n1 0 lfsaw 2 *")
        app.buttons["Hide keyboard"].firstMatch.tap()
        let console = app.textViews["Console"]

        app.buttons.matching(identifier: "Run block").element(boundBy: 0).tap()
        plotTopOfStack()
        XCTAssertTrue(app.buttons["Plot"].waitForExistence(timeout: 5), "the waveform switches to the plot")
        if app.buttons["Console"].exists {
            app.buttons["Console"].tap()
            expectation(for: NSPredicate(format: "value CONTAINS 'plot: 9 values'"), evaluatedWith: console)
            waitForExpectations(timeout: 3)
            app.buttons["Scope"].tap()
        }
        screenshot("plot-values")

        app.buttons.matching(identifier: "Run block").element(boundBy: 1).tap()
        plotTopOfStack()
        sleep(1)
        screenshot("plot-signal")
        waveform().pinch(withScale: 4, velocity: 4)
        sleep(1)
        screenshot("plot-zoomed")
        if app.buttons["Console"].exists {
            app.buttons["Console"].tap()
            XCTAssertTrue((console.value as? String ?? "").contains("plot: first"), "an endless signal is cut off")
            app.buttons["Scope"].tap()
        }
        app.buttons["Close Plot"].tap()
        screenshot("plot-closed")
        XCTAssertFalse(app.buttons["Output"].exists, "the plot and its Output/Plot switch are gone")
        XCTAssertFalse(app.buttons["Close Plot"].exists)
    }

    func testZoomOutShowsEnvelope() {
        _ = newDocument(with: "440 0 sinosc 2 0 lfsaw 1 + .5 * * .3 * play")
        app.buttons["Hide keyboard"].firstMatch.tap()
        app.buttons["Run block"].firstMatch.tap()
        if app.buttons["Scope"].exists { app.buttons["Scope"].tap() }
        if app.buttons["Output"].exists { app.buttons["Output"].tap() }
        waveform().pinch(withScale: 0.05, velocity: -4)
        sleep(3)
        screenshot("output-envelope")
        waveform().doubleTap()
        app.buttons["Stop"].firstMatch.tap()
    }

    private func openDocument(_ name: String) {
        // firstMatch: a full query of the screen times out while the long Examples text is showing.
        app.buttons["Documents"].firstMatch.tap()
        app.buttons[name].firstMatch.tap()
    }

    func testSwitchingDocumentsKeepsTheScrollPosition() {
        openDocument("Examples")
        let editor = app.textViews.firstMatch
        for _ in 0..<6 { editor.swipeUp(velocity: .fast) }
        sleep(1)
        // The margin buttons are pooled; the first one is beside the topmost visible block.
        let firstRun = app.buttons.matching(identifier: "Run block").firstMatch
        XCTAssertTrue(firstRun.exists)
        let before = firstRun.frame
        screenshot("examples-scrolled")

        openDocument("Scratch")
        openDocument("Examples")
        sleep(1)
        let after = firstRun.frame
        screenshot("examples-returned")
        XCTAssertEqual(after.minY, before.minY, accuracy: 2, "back where we were")
    }

    private func setUIMode(_ mode: String) {
        app.buttons["More"].firstMatch.tap()
        app.buttons["UI Mode"].firstMatch.tap()
        app.buttons[mode].firstMatch.tap()
    }

    func testUIModeMenu() {
        setUIMode("Dark")
        sleep(1)
        screenshot("ui-dark")
        setUIMode("Light")
        sleep(1)
        screenshot("ui-light")
        setUIMode("Auto")
    }

    func testRevertBuiltInFile() {
        openDocument("Builtin Examples")
        app.buttons["Documents"].firstMatch.tap()
        XCTAssertFalse(app.buttons["Revert to Original…"].exists, "nothing to revert yet")
        app.buttons["Builtin Examples"].firstMatch.tap() // close the menu

        if app.buttons["Edit"].exists { app.buttons["Edit"].tap() } // phones start out reading
        app.textViews.firstMatch.tap()
        app.textViews.firstMatch.typeText("CORRUPTED ")
        sleep(2) // saved after a second

        app.buttons["Documents"].firstMatch.tap()
        app.buttons["Revert to Original…"].firstMatch.tap()
        app.buttons["Revert"].firstMatch.tap()
        sleep(1)
        let text = app.textViews.firstMatch.value as? String ?? ""
        XCTAssertFalse(text.contains("CORRUPTED"), "the original is back")
        app.buttons["Documents"].firstMatch.tap()
        XCTAssertFalse(app.buttons["Revert All Built-in Files…"].exists, "nothing left to revert")
    }

    func testCodeIsWarmedAtStartup() {
        if app.buttons["Console"].exists { app.buttons["Console"].tap() }
        let console = app.textViews["Console"]
        expectation(for: NSPredicate(format: "value CONTAINS 'code warmed'"), evaluatedWith: console)
        waitForExpectations(timeout: 5)
        let line = (console.value as? String ?? "").split(separator: "\n").first { $0.hasPrefix("code warmed") } ?? ""
        print("startup: \(line)")
    }

    /// Plays something busy and captures every layout, for checking screen size handling by eye.
    func testLayouts() {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        _ = newDocument(with: "((.4 0 lfsaw) 2 * ([8 7.23] 0 lfsaw) .25 * 9.667 + + exp2) 0 sinosc .04 * .2 0 4 combn play")
        app.buttons["Run block"].firstMatch.tap()
        if app.buttons["Hide keyboard"].isHittable { app.buttons["Hide keyboard"].firstMatch.tap() }
        if app.buttons["Scope"].exists { app.buttons["Scope"].tap() }
        sleep(2)
        screenshot("\(device)-portrait")
        XCTAssertTrue(app.navigationBars.buttons["Stop"].isHittable, "Stop is right on the toolbar, not in an overflow menu")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        screenshot("\(device)-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["Stop"].firstMatch.tap()
    }
}

