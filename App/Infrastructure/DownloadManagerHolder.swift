import Foundation
import LocallyStorage

/// Environment-injectable holder so SwiftUI views can reach the shared
/// DownloadManager without a singleton.
@Observable
final class DownloadManagerHolder {
    var manager: DownloadManager?

    init(manager: DownloadManager? = nil) {
        self.manager = manager
    }
}
