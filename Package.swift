// swift-tools-version: 6.0
import PackageDescription
import Foundation

// llama.cpp integration (see DEPENDENCIES.md). Pinned to the v0.5.0 commit:
//   - Apple: binary target with the official xcframework from release b11146,
//     which is cut at exactly the v0.5.0 tag commit (the v0.5.0 GitHub
//     release itself ships no xcframework asset).
//   - Linux: systemLibrary pointing at .deps/llama-install, produced by
//     scripts/build-llama-linux.sh (clones the v0.5.0 tag). Plain
//     `swift build` without the install works fine — the GGUF runtime then
//     reports llama.cpp as not linked.
// LOCALLY_LLAMA=1 forces the Linux link even if the install dir is missing
// (used in CI where the build step runs first).
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let linuxInstallDir = ".deps/llama-install"
let linuxInstallAbs = "\(packageRoot)/\(linuxInstallDir)"
let clamaDir = "\(packageRoot)/Sources/CLlama"
// CLlama/shim.h includes "include/llama.h" where `include` is a symlink
// (gitignored) into the install dir. A fresh checkout has the install dir
// but not the symlink; recreate it here so Package.swift never builds a
// module whose header is unresolvable.
func resolveCLlamaInclude() -> Bool {
    let fm = FileManager.default
    let headerViaLink = "\(clamaDir)/include/llama.h"
    if fm.fileExists(atPath: headerViaLink) { return true }
    let installedInclude = "\(linuxInstallAbs)/include"
    guard fm.fileExists(atPath: "\(installedInclude)/llama.h") else { return false }
    // Symlink missing or broken: try to (re)create it.
    try? fm.removeItem(atPath: "\(clamaDir)/include")
    try? fm.createSymbolicLink(atPath: "\(clamaDir)/include", withDestinationPath: installedInclude)
    return fm.fileExists(atPath: headerViaLink)
}
let linuxLlamaAvailable: Bool = {
    let forced = ProcessInfo.processInfo.environment["LOCALLY_LLAMA"] == "1"
    return forced || resolveCLlamaInclude()
}()

var targets: [Target] = [
    .target(name: "LocallyCore"),
    .target(name: "LocallyDevice", dependencies: ["LocallyCore"]),
    .target(name: "LocallyHF", dependencies: ["LocallyCore"]),
    .target(name: "LocallyCompatibility", dependencies: ["LocallyCore", "LocallyDevice"]),
    .target(name: "LocallyStorage", dependencies: ["LocallyCore"]),
    .target(name: "LocallyRuntime", dependencies: ["LocallyCore"]),

    .testTarget(name: "LocallyCoreTests", dependencies: ["LocallyCore"]),
    .testTarget(name: "LocallyDeviceTests", dependencies: ["LocallyDevice"]),
    .testTarget(name: "LocallyHFTests", dependencies: ["LocallyHF"]),
    .testTarget(
        name: "LocallyCompatibilityTests",
        dependencies: ["LocallyCompatibility", "LocallyCore", "LocallyDevice"]
    ),
    .testTarget(name: "LocallyStorageTests", dependencies: ["LocallyStorage", "LocallyCore"]),
    .testTarget(name: "LocallyRuntimeTests", dependencies: ["LocallyRuntime", "LocallyCore"]),
    .testTarget(
        name: "LocallyE2ETests",
        dependencies: [
            "LocallyCore", "LocallyHF", "LocallyDevice",
            "LocallyCompatibility", "LocallyStorage", "LocallyRuntime",
        ]
    ),
]

#if os(Linux)
// ZIP extraction in LocallyStorage inflates via system zlib on Linux
// (Compression.framework is Apple-only).
targets.append(.systemLibrary(name: "CZlib", path: "Sources/CZlib"))
if let storageIndex = targets.firstIndex(where: { $0.name == "LocallyStorage" }) {
    targets[storageIndex] = .target(
        name: "LocallyStorage",
        dependencies: ["LocallyCore", "CZlib"]
    )
}
if linuxLlamaAvailable {
    // CLlama/shim.h includes "include/llama.h" where `include` is a symlink
    // into the install dir, so dependents need no extra -I flags.
    targets.append(.systemLibrary(name: "CLlama", path: "Sources/CLlama"))
    targets.append(.target(
        name: "LocallyLlama",
        dependencies: ["CLlama"],
        linkerSettings: [
            .unsafeFlags([
                "-L\(linuxInstallAbs)/lib",
                "-Xlinker", "-rpath", "-Xlinker", "\(linuxInstallAbs)/lib",
            ]),
            .linkedLibrary("llama"),
            .linkedLibrary("ggml"),
            .linkedLibrary("ggml-base"),
            .linkedLibrary("ggml-cpu"),
        ]
    ))
    let runtimeIndex = targets.firstIndex { $0.name == "LocallyRuntime" }!
    targets[runtimeIndex] = .target(
        name: "LocallyRuntime",
        dependencies: ["LocallyCore", "LocallyLlama"]
    )
}
#else
// Apple: official xcframework from the llama.cpp release whose commit is the
// v0.5.0 tag (b11146). See DEPENDENCIES.md. That release ships iOS-device and
// macOS slices only — no iOS Simulator — so CI builds a local xcframework
// with a simulator slice via scripts/build-llama-apple.sh into
// .deps/llama-apple/llama.xcframework; when present, that local path wins.
let appleLocalXCFramework = "\(packageRoot)/.deps/llama-apple/llama.xcframework"
if FileManager.default.fileExists(atPath: "\(appleLocalXCFramework)/Info.plist") {
    targets.append(.binaryTarget(name: "llama", path: ".deps/llama-apple/llama.xcframework"))
} else {
    targets.append(.binaryTarget(
        name: "llama",
        url: "https://github.com/ggml-org/llama.cpp/releases/download/b11146/llama-b11146-xcframework.zip",
        checksum: "1c306afe9fe68a90c4bdc74619d8558d6e0754f085deb105dd2d70293a9a964f"
    ))
}
targets.append(.target(name: "LocallyLlama", dependencies: ["llama"]))
let runtimeIndex = targets.firstIndex { $0.name == "LocallyRuntime" }!
targets[runtimeIndex] = .target(
    name: "LocallyRuntime",
    dependencies: ["LocallyCore", "LocallyLlama"]
)
#endif

let package = Package(
    name: "Locally",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LocallyCore", targets: ["LocallyCore"]),
        .library(name: "LocallyDevice", targets: ["LocallyDevice"]),
        .library(name: "LocallyHF", targets: ["LocallyHF"]),
        .library(name: "LocallyCompatibility", targets: ["LocallyCompatibility"]),
        .library(name: "LocallyStorage", targets: ["LocallyStorage"]),
        .library(name: "LocallyRuntime", targets: ["LocallyRuntime"]),
    ],
    targets: targets
)
