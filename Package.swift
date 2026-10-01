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
let linuxLlamaAvailable: Bool = {
    let forced = ProcessInfo.processInfo.environment["LOCALLY_LLAMA"] == "1"
    let installed = FileManager.default.fileExists(
        atPath: "\(linuxInstallAbs)/include/llama.h")
    return forced || installed
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
]

#if os(Linux)
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
// v0.5.0 tag (b11146). See DEPENDENCIES.md.
targets.append(.binaryTarget(
    name: "llama",
    url: "https://github.com/ggml-org/llama.cpp/releases/download/b11146/llama-b11146-xcframework.zip",
    checksum: "1c306afe9fe68a90c4bdc74619d8558d6e0754f085deb105dd2d70293a9a964f"
))
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
