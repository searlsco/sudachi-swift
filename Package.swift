// swift-tools-version: 6.0
import PackageDescription

// NOTE: `url` + `checksum` below are rewritten by the release workflow
// (.github/workflows/release.yml) on each release. Local development and tests
// use swift/Sudachi/Package.swift, which links the locally built
// build/Sudachi.xcframework instead.
let package = Package(
    name: "sudachi-swift",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "Sudachi", targets: ["Sudachi"]),
    ],
    targets: [
        .binaryTarget(
            name: "sudachi_swiftFFI",
            url: "https://github.com/searlsco/sudachi-swift/releases/download/v0.4.0/Sudachi.xcframework.zip",
            checksum: "7d64e8ba0bc12cc058e1efef82a0c690677ad13dcae7d6dfce415c0df6fa5616"
        ),
        .target(
            name: "Sudachi",
            dependencies: ["sudachi_swiftFFI"],
            path: "swift/Sudachi/Sources/Sudachi"
        ),
        .testTarget(
            name: "SudachiTests",
            dependencies: ["Sudachi"],
            path: "swift/Sudachi/Tests/SudachiTests"
        ),
    ]
)
