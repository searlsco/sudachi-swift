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
        .visionOS(.v1),
        .macOS(.v14),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "Sudachi", targets: ["Sudachi"]),
    ],
    targets: [
        .binaryTarget(
            name: "sudachi_swiftFFI",
            url: "https://github.com/searlsco/sudachi-swift/releases/download/v0.4.1/Sudachi.xcframework.zip",
            checksum: "a5e28194fdc2ea899b1451f718a9833f1b313c1c7b4176192a3b8eae0dbc454d"
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
