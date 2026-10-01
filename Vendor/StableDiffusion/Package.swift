// swift-tools-version: 5.10
// Vendored copy of apple/ml-stable-diffusion — see VENDORED.md.

import PackageDescription

let package = Package(
    name: "stable-diffusion",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "StableDiffusion", targets: ["StableDiffusion"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "StableDiffusion",
            path: "Sources/StableDiffusion"),
    ]
)
