// swift-tools-version: 6.0
import PackageDescription

// NOTE: `url` + `checksum` below are rewritten automatically by the release
// workflow (.github/workflows/release.yml) on each tagged release — the
// all-zero checksum below is a pre-first-release placeholder. Between releases
// they may lag; local development/tests use swift/Sudachi/Package.swift,
// which links the locally built build/Sudachi.xcframework instead.
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
            url: "https://github.com/searlsco/sudachi-swift/releases/download/v0.2.0/Sudachi.xcframework.zip",
            checksum: "8cc04a1b21f74a728904b579eb9728837181ad365fb500d940cd026a94d20491"
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
