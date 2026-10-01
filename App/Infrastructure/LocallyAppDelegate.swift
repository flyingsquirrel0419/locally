import SwiftUI
import UIKit

/// UIApplicationDelegate adaptor for background URLSession relaunch events.
final class LocallyAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadRuntime.shared.handleEventsForBackgroundURLSession(identifier,
                                                                   completionHandler: completionHandler)
    }
}
