import Foundation
import LocallyCore

/// Cross-tab navigation state. "Run in Playground" on Model Detail sets
/// `playgroundModelID` (the InstalledModel id) and flips the tab; the
/// Playground picks the model up, runs it, and clears the request so the
/// picker stays in charge afterwards.
@Observable
final class AppNavigation {
    var playgroundModelID: String?

    init(playgroundModelID: String? = nil) {
        self.playgroundModelID = playgroundModelID
    }
}
