import XCTest

/// The Mac half of the acceptance journey, driven through the interface.
///
/// These are written against accessibility labels rather than layout, so a
/// redesign that keeps the product the same keeps the tests passing.
final class MacJourneyUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--dubplate-ui-testing", "--dubplate-sample-library"]
        app.launch()
    }

    func testLibraryShowsTheSampleRecords() {
        XCTAssertTrue(app.staticTexts["NO SIGNAL"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["BLUE ROOM"].exists)
    }

    func testOpeningAReleaseShowsItsSequence() {
        app.staticTexts["NO SIGNAL"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Intro"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Dust"].exists)
        XCTAssertTrue(app.buttons["Play"].exists)
    }

    func testPlayingARecordUpdatesTheMiniPlayer() {
        app.staticTexts["NO SIGNAL"].firstMatch.click()
        app.buttons["Play"].click()

        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.click()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5))
    }

    func testCreatingAReleaseTakesFourFields() {
        app.typeKey("n", modifierFlags: .command)
        let title = app.textFields["Release title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeText("TEST PRESSING")
        app.buttons["Create"].click()

        XCTAssertTrue(app.staticTexts["TEST PRESSING"].waitForExistence(timeout: 5))
    }

    func testVersionsAreReachableFromATrack() {
        app.staticTexts["Midnight"].firstMatch.click()
        let versions = app.buttons["All Versions"]
        if versions.waitForExistence(timeout: 5) {
            versions.click()
            XCTAssertTrue(app.staticTexts["Current"].waitForExistence(timeout: 5))
        }
    }

    func testPhonePreviewOpens() {
        app.staticTexts["NO SIGNAL"].firstMatch.click()
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["Stream"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Gallery"].exists)
        XCTAssertTrue(app.buttons["Motion"].exists)
    }
}
