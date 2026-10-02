import XCTest

/// Screenshot suite: launches the app with -UITestFixtures (DEBUG-only
/// seeder writes fixture models + one in-flight download into Application
/// Support) and captures every tab in the current appearance.
///
/// PNGs are written to the directory named by -UITestScreenshotDir <path>
/// (passed through by the CI workflow) AND attached to the test result with
/// .keepAlways, so `xcrun xcresulttool export attachments` is a fallback.
///
/// Run order within a test method is fixed; method order follows
/// `testCaseOrdering` (alphabetical by default) — file prefixes keep the
/// artifact names stable regardless.
final class ScreenshotTests: XCTestCase {

    private var app: XCUIApplication!
    private var outputDir: URL?

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments.append("-UITestFixtures")
        // Optional Dynamic Type override (XXXL pass): the workflow sets
        // CONTENT_SIZE_CATEGORY=UICTContentSizeCategoryAX5 for that run.
        if let category = ProcessInfo.processInfo.environment["CONTENT_SIZE_CATEGORY"],
           !category.isEmpty {
            app.launchArguments.append(contentsOf: ["-UIPreferredContentSizeCategoryName", category])
        }
        // XCUITest injects launchEnvironment into the app under test, so
        // SCREENSHOT_DIR set by the workflow reaches the app process.
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            app.launchEnvironment["SCREENSHOT_DIR"] = dir
            outputDir = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        app.launch()
        // Let launch tasks (registry load, restore, fixture seeding) settle.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        sleep(3)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Full-screen screenshot → XCTAttachment + PNG file on the host.
    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let outputDir {
            try? shot.pngRepresentation.write(to: outputDir.appendingPathComponent("\(name).png"))
        }
    }

    private func tapTab(_ label: String) {
        let button = app.tabBars.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "tab \(label) missing")
        button.tap()
        sleep(1)
    }

    // MARK: - Tabs

    /// Home, Models (library + detail + add sheet), Downloads, Settings,
    /// Diagnostics — one continuous pass so the fixture state stays warm.
    func testA_mainScreens() {
        tapTab("Home")
        capture("01-home")

        tapTab("Models")
        sleep(2)
        capture("02-models")

        // Model detail via the first library row.
        let firstRow = app.cells.firstMatch
        if firstRow.waitForExistence(timeout: 5) {
            firstRow.tap()
            sleep(1)
            capture("03-model-detail")
            app.navigationBars.buttons.firstMatch.tap() // back
            sleep(1)
        }

        // Add Model sheet (empty — analysis needs network, not available).
        let add = app.navigationBars.buttons["Add model"]
        if add.waitForExistence(timeout: 5) {
            add.tap()
            sleep(1)
            capture("04-add-model")
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.exists { cancel.tap() }
            sleep(1)
        }

        tapTab("Downloads")
        sleep(2)
        // Fixture job restored from disk: restore() flips .downloading to
        // .paused, so the row shows Paused with real progress bytes.
        capture("05-downloads-paused")

        // Resume briefly → row goes active with progress; capture, then
        // pause again for the paused-with-controls state.
        let resume = app.buttons["Resume"].firstMatch
        if resume.waitForExistence(timeout: 5) {
            resume.tap()
            sleep(2)
            capture("05b-downloads-active")
            let pause = app.buttons["Pause"].firstMatch
            if pause.waitForExistence(timeout: 3) {
                pause.tap()
                sleep(1)
                capture("05c-downloads-paused-again")
            }
        }

        tapTab("Settings")
        capture("06-settings")

        let diagnostics = app.cells["Diagnostics"]
        if diagnostics.waitForExistence(timeout: 5) {
            diagnostics.tap()
            sleep(1)
            capture("07-diagnostics")
        }
    }

    /// Playground: fixture GGUF model loads for real; a chat exchange is
    /// attempted and the result (messages or an honest load error) captured.
    func testB_playgroundChat() {
        tapTab("Playground")
        sleep(2)

        let picker = app.buttons["Model"]
        guard picker.waitForExistence(timeout: 8) else {
            capture("08-playground-empty")
            return
        }
        picker.tap()
        let option = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'TinyStories'")).firstMatch
        if option.waitForExistence(timeout: 5) {
            option.tap()
        } else {
            // Dismiss the picker and capture whatever state we have.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            capture("08-playground-empty")
            return
        }

        // Model load (GGUF parse + llama.cpp init) can take a while.
        sleep(8)
        capture("08-playground-chat")

        let input = app.textFields["Message"]
        guard input.waitForExistence(timeout: 5) else { return }
        input.tap()
        input.typeText("Hello")
        let send = app.buttons["Send"]
        if send.waitForExistence(timeout: 3) { send.tap() }
        // Let generation stream for a bit; capture regardless of completion.
        sleep(10)
        capture("09-playground-chat-generating")
    }
}
