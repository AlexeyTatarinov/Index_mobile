// SPDX-License-Identifier: GPL-3.0-or-later
//
// Used only by scripts/screenshots.sh: taps "Allow Full Access" in the photo
// permission dialog, because `simctl privacy grant` does not cover full access.

import XCTest

final class GrantPhotosAccessTests: XCTestCase {
    func testGrantFullPhotoAccess() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTab", "log"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var tapped = 0
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && tapped < 2 {
            let candidates = [
                springboard.buttons["Allow Full Access"],
                app.buttons["Allow Full Access"],
                springboard.buttons["Allow Access to All Photos"],
                app.buttons["Allow Access to All Photos"],
            ]
            if let button = candidates.first(where: { $0.exists }) {
                button.tap()
                tapped += 1
                sleep(2)
            } else {
                sleep(1)
            }
        }
        XCTAssertGreaterThan(tapped, 0, "Photo permission dialog did not appear")
    }
}
