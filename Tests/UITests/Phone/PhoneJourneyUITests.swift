import XCTest

/// The listening half of the acceptance journey.
final class PhoneJourneyUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--dubplate-ui-testing", "--dubplate-sample-library"]
        app.launch()
    }

    func testHomeLeadsWithArtwork() {
        XCTAssertTrue(app.staticTexts["NO SIGNAL"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your Music"].exists)
    }

    func testAReleasePageReadsLikeARecord() {
        app.staticTexts["NO SIGNAL"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Shuffle"].exists)
        XCTAssertTrue(app.staticTexts["Intro"].exists)
    }

    func testPlayingOpensTheMiniPlayerAndThenThePlayer() {
        app.staticTexts["NO SIGNAL"].firstMatch.tap()
        app.buttons["Play"].tap()

        let miniPlayer = app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH 'Now playing'")
        ).firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        miniPlayer.tap()

        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Stream"].exists)
    }

    func testSwitchingPreviewModes() {
        app.staticTexts["NO SIGNAL"].firstMatch.tap()
        app.buttons["Play"].tap()
        app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH 'Now playing'")
        ).firstMatch.tap()

        app.buttons["Gallery"].tap()
        XCTAssertTrue(app.buttons["Gallery"].isSelected)
        app.buttons["Motion"].tap()
        XCTAssertTrue(app.buttons["Motion"].isSelected)
    }

    func testVersionPickerIsSecondaryButReachable() {
        app.staticTexts["Midnight"].firstMatch.tap()
        let versionsButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Versions of'")
        ).firstMatch
        if versionsButton.waitForExistence(timeout: 5) {
            versionsButton.tap()
            XCTAssertTrue(app.staticTexts["Versions"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Set as Current"].firstMatch.exists)
        }
    }

    func testDownloadButtonExplainsItself() {
        app.staticTexts["NO SIGNAL"].firstMatch.tap()
        let download = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Download' OR label CONTAINS 'Remove Download'")
        ).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5))
    }
}
