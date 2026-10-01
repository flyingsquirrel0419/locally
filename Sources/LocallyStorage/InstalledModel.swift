import Foundation
import LocallyCore

/// An installed model: the descriptor snapshot taken at install time plus
/// bookkeeping (usage, per-user overrides, benchmark samples).
public struct InstalledModel: Sendable, Hashable, Codable, Identifiable {
    /// "\(repoID)@\(revision)" — unique per installed revision.
    public var id: String
    public var repoID: String
    /// Pinned commit sha when the API provided one, else the requested ref.
    public var revision: String
    /// Selected runtime (the override when set, else the descriptor's first).
    public var runtime: RuntimeKind?
    public var formats: [ModelFormat]
    public var quantization: Quantization?
    public var sizeOnDisk: Int64
    public var installedAt: Date
    public var lastUsedAt: Date?
    /// Snapshot of the descriptor at install time.
    public var descriptor: ModelDescriptor
    /// User-chosen runtime override; nil follows the descriptor default.
    public var runtimeOverride: RuntimeKind?
    /// User-chosen context length override, bounded by descriptor.contextLength.
    public var contextOverride: Int?
    /// Real benchmark samples recorded on-device; never fabricated.
    public var benchmarks: [InferenceMetadata]
    /// Set by reconcile when the record exists but files are gone.
    public var hasMissingFiles: Bool

    public init(repoID: String, revision: String, descriptor: ModelDescriptor,
                sizeOnDisk: Int64, installedAt: Date = Date()) {
        self.id = "\(repoID)@\(revision)"
        self.repoID = repoID
        self.revision = revision
        self.runtime = descriptor.supportedRuntimes.first
        self.formats = descriptor.formats
        self.quantization = descriptor.quantization
        self.sizeOnDisk = sizeOnDisk
        self.installedAt = installedAt
        self.lastUsedAt = nil
        self.descriptor = descriptor
        self.runtimeOverride = nil
        self.contextOverride = nil
        self.benchmarks = []
        self.hasMissingFiles = false
    }
}

/// Reports whether a runtime currently has a model loaded; the app layer
/// injects the real check once RuntimeRouter exists. Deletion is refused
/// for loaded models.
public protocol ModelLoadedChecking: Sendable {
    func isModelLoaded(repoID: String, revision: String) async -> Bool
}

/// Default: nothing is loaded (no runtime exists yet this week).
public struct NoModelLoadedChecker: ModelLoadedChecking {
    public init() {}
    public func isModelLoaded(repoID: String, revision: String) async -> Bool { false }
}

/// Which runtimes an installed model can use. The default reads the
/// descriptor snapshot; later weeks substitute a real RuntimeRouter probe.
public protocol RuntimeAvailabilityProvider: Sendable {
    func availableRuntimes(for model: InstalledModel) -> [RuntimeKind]
}

public struct DescriptorRuntimeAvailability: RuntimeAvailabilityProvider {
    public init() {}
    public func availableRuntimes(for model: InstalledModel) -> [RuntimeKind] {
        model.descriptor.supportedRuntimes
    }
}
