import XCTest
import SwiftUI
import LocallyCore
import LocallyStorage
@testable import Locally

/// Hosted screenshot preview tests: render REAL app views (from the Locally
/// target) inside the app process and capture them via
/// XCUIScreen.main.screenshot(). The UI-test target cannot see the app's
/// internal view types, but this unit-test bundle is compiled with
/// @testable import against it and runs inside the app — the same trick the
/// smoke tests use to prove linking.
///
/// Fixture state comes from the -UITestFixtures launch path (app init has
/// already seeded the registry and download store when tests start, because
/// the hosted test runner launches the full app first).
final class ScreenshotPreviewTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    @MainActor
    private func render<V: View>(_ view: V, name: String) {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func libraryHolder() -> ModelLibraryHolder {
        ModelLibraryRuntime.shared.holder
    }

    // MARK: - Previews

    @MainActor
    func testPreviewHome() {
        render(HomeView(), name: "preview-home")
    }

    @MainActor
    func testPreviewModels() {
        render(ModelsView(), name: "preview-models")
    }

    @MainActor
    func testPreviewModelDetail() {
        let viewModel = ModelLibraryViewModel()
        if let registry = libraryHolder().registry {
            viewModel.attach(registry: registry)
        }
        // attach() loads asynchronously; give it a couple of run-loop turns.
        var first = viewModel.models.first
        for _ in 0..<5 where first == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            first = viewModel.models.first
        }
        guard let model = first else {
            XCTFail("fixture registry is empty")
            return
        }
        render(ModelDetailView(modelID: model.id, viewModel: viewModel),
               name: "preview-model-detail")
    }

    @MainActor
    func testPreviewAddModel() {
        render(AddModelSheet(), name: "preview-add-model")
    }

    @MainActor
    func testPreviewDownloads() {
        render(DownloadsView(), name: "preview-downloads")
    }

    @MainActor
    func testPreviewPlayground() {
        render(PlaygroundView(), name: "preview-playground")
    }

    @MainActor
    func testPreviewSettings() {
        render(SettingsView(), name: "preview-settings")
    }

    @MainActor
    func testPreviewDiagnostics() {
        render(DiagnosticsView(), name: "preview-diagnostics")
    }
}
