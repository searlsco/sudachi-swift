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
    ],
    products: [
        .library(name: "Sudachi", targets: ["Sudachi"]),
    ],
    targets: [
        .binaryTarget(
            name: "sudachi_swiftFFI",
            url: "https://github.com/searlsco/sudachi-swift/releases/download/v0.3.3/Sudachi.xcframework.zip",
            checksum: "95eefc796c79b8715ebad8e8c0908abad16f866c5a6e170b2d22584d75ee5ae6"
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
