// swift-tools-version: 6.0
import PackageDescription

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
    targets: [
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
)
