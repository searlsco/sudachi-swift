// swift-tools-version: 6.0
import PackageDescription

// Local development / test manifest: links the xcframework you build with
// scripts/build-ios.sh. The root Package.swift is the one remote consumers use.
let package = Package(
    name: "Sudachi",
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
            path: "../../build/Sudachi.xcframework"
        ),
        .target(
            name: "Sudachi",
            dependencies: ["sudachi_swiftFFI"],
            path: "Sources/Sudachi"
        ),
        .testTarget(
            name: "SudachiTests",
            dependencies: ["Sudachi"],
            path: "Tests/SudachiTests"
        ),
    ]
)
