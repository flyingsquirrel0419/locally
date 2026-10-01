import Foundation
import LocallyRuntime

/// Policy-backed thermal pacer: reads the current inter-token delay from
/// ResourcePolicyObserver on every token, so throttling starts and stops
/// without re-creating the runtimes. Delay of 0 means no pacing.
struct PolicyGenerationPacer: GenerationPacer {
    func pace() async {
        let delay = await MainActor.run {
            ResourcePolicyObserver.shared.interTokenDelayNanoseconds
        }
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
    }
}
