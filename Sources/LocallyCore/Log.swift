import Foundation

#if canImport(os)
import os
#endif

/// Centralized logging. On Apple platforms this wraps OSLog; elsewhere it is
/// a stderr fallback. Never log tokens, credentials, or user content.
public enum Log {
    public enum Category: String, Sendable, CaseIterable {
        case hf = "HF"
        case download = "Download"
        case runtime = "Runtime"
        case mlx = "MLX"
        case gguf = "GGUF"
        case coreml = "CoreML"
        case device = "Device"
        case compatibility = "Compatibility"
        case storage = "Storage"
        case inference = "Inference"
        case ui = "UI"
    }

    private static let subsystem = "me.teamwicked.locally"

    #if canImport(os)
    private static let lock = NSLock()
    private static var loggers: [Category: os.Logger] = [:]

    private static func logger(for category: Category) -> os.Logger {
        lock.lock()
        defer { lock.unlock() }
        if let existing = loggers[category] { return existing }
        let created = os.Logger(subsystem: subsystem, category: category.rawValue)
        loggers[category] = created
        return created
    }
    #endif

    public static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        #if canImport(os)
        logger(for: category).debug("\(message(), privacy: .public)")
        #else
        FileHandle.standardError.write(Data("[\(category.rawValue)] \(message())\n".utf8))
        #endif
    }

    public static func info(_ category: Category, _ message: @autoclosure () -> String) {
        #if canImport(os)
        logger(for: category).info("\(message(), privacy: .public)")
        #else
        FileHandle.standardError.write(Data("[\(category.rawValue)] \(message())\n".utf8))
        #endif
    }

    public static func warning(_ category: Category, _ message: @autoclosure () -> String) {
        #if canImport(os)
        logger(for: category).warning("\(message(), privacy: .public)")
        #else
        FileHandle.standardError.write(Data("[\(category.rawValue)][warn] \(message())\n".utf8))
        #endif
    }

    public static func error(_ category: Category, _ message: @autoclosure () -> String) {
        #if canImport(os)
        logger(for: category).error("\(message(), privacy: .public)")
        #else
        FileHandle.standardError.write(Data("[\(category.rawValue)][error] \(message())\n".utf8))
        #endif
    }
}
