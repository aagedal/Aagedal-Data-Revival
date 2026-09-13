import XCTest

@MainActor
final class RecoveryWorkflowUITests: XCTestCase {
    func testImageScanReviewExportAndSessionReopen() throws {
        continueAfterFailure = false

        let root = URL(fileURLWithPath: "/private/tmp/DataRevivalUITests", isDirectory: true)
        let catalog = root.appendingPathComponent("catalog", isDirectory: true)
        let recoveryDestination = root.appendingPathComponent("recovery", isDirectory: true)
        let exportDestination = root.appendingPathComponent("export", isDirectory: true)
        let source = root.appendingPathComponent("ui-test-card.img")
        let fixture = root.appendingPathComponent("fixture.jpg")

        try? FileManager.default.removeItem(at: root)
        for directory in [root, catalog, recoveryDestination, exportDestination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data(repeating: 0xA5, count: 1_024).write(to: source)
        try benchmarkJPEGData().write(to: fixture)

        let app = XCUIApplication()
        app.launchArguments = [
            "--data-revival-ui-testing",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launchEnvironment = [
            "DATA_REVIVAL_UI_TEST_CATALOG": catalog.path,
            "DATA_REVIVAL_UI_TEST_SOURCE": source.path,
            "DATA_REVIVAL_UI_TEST_RECOVERY_DESTINATION": recoveryDestination.path,
            "DATA_REVIVAL_UI_TEST_FIXTURE": fixture.path,
            "DATA_REVIVAL_UI_TEST_EXPORT_DESTINATION": exportDestination.path
        ]
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        app.launch()

        let chooseImage = app.buttons["Choose image…"]
        if !chooseImage.waitForExistence(timeout: 1) {
            let newWindow = app.menuBars.menuItems["New Data Revival Window"]
            XCTAssertTrue(newWindow.exists)
            newWindow.click()
        }
        XCTAssertTrue(chooseImage.waitForExistence(timeout: 5))
        chooseImage.click()

        let recoverPhotos = app.buttons["Recover Photos…"]
        XCTAssertTrue(recoverPhotos.waitForExistence(timeout: 5))
        recoverPhotos.click()

        XCTAssertTrue(app.staticTexts["Recovered files"].waitForExistence(timeout: 10))
        let resultsTable = app.descendants(matching: .any)["recovered-files-table"]
        XCTAssertTrue(resultsTable.waitForExistence(timeout: 5))
        XCTAssertTrue(
            resultsTable.descendants(matching: .staticText)["recovered.jpg"]
                .waitForExistence(timeout: 5)
        )

        let search = app.textFields["recovered-files-search"]
        XCTAssertTrue(search.exists)
        search.click()
        search.typeText("no-match")
        expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: resultsTable.descendants(matching: .staticText)["recovered.jpg"]
        )
        waitForExpectations(timeout: 5)

        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        let recoveredFile = resultsTable.descendants(matching: .staticText)["recovered.jpg"]
        XCTAssertTrue(recoveredFile.waitForExistence(timeout: 5))
        recoveredFile.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["recovered-file-inspector"]
                .waitForExistence(timeout: 5)
        )

        let export = app.buttons["Export Selected…"]
        XCTAssertTrue(export.isEnabled)
        export.click()
        let confirmation = app.staticTexts["Export complete"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        app.buttons["action-button-1"].click()
        XCTAssertTrue(waitForFile(at: root.appendingPathComponent("export/recovered.jpg")))

        app.terminate()
        app.launch()

        let sessionsWorkspace = app.descendants(matching: .any)["workspace-Recovery sessions"]
        if !sessionsWorkspace.waitForExistence(timeout: 1) {
            app.menuBars.menuItems["New Data Revival Window"].click()
        }
        XCTAssertTrue(sessionsWorkspace.waitForExistence(timeout: 5))
        sessionsWorkspace.click()
        let sessionList = app.descendants(matching: .any)["recovery-sessions-list"]
        XCTAssertTrue(sessionList.waitForExistence(timeout: 5))
        let savedSession = sessionList.staticTexts["ui-test-card.img"]
        XCTAssertTrue(savedSession.waitForExistence(timeout: 5))
        savedSession.click()
        XCTAssertTrue(app.staticTexts["Recovered files"].waitForExistence(timeout: 5))
        let reopenedResult = app.descendants(matching: .any)["recovered-files-table"]
            .descendants(matching: .staticText)["recovered.jpg"]
        XCTAssertTrue(reopenedResult.exists)
    }

    private func benchmarkJPEGData() throws -> Data {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let encodedURL = repositoryRoot.appendingPathComponent(
            "Benchmarks/RecoveryQuality/v1/originals/synthetic-gradient.jpg.base64"
        )
        let encoded = try String(contentsOf: encodedURL, encoding: .utf8)
        return try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
    }

    private func waitForFile(at url: URL, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

}
