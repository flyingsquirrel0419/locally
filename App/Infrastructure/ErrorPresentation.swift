import Foundation
import LocallyCore

/// User-facing rendering for any error: `LocallyError.userMessage` when the
/// error is one of ours, a generic honest message otherwise — internal
/// `localizedDescription` strings (URLError codes, CocoaError domains) are
/// never shown to the user.
enum ErrorPresentation {
    static func userMessage(for error: Error) -> String {
        if let locally = error as? LocallyError {
            return locally.userMessage
        }
        if error is CancellationError {
            return String(localized: "error.cancelled")
        }
        return String(localized: "error.generic")
    }
}
