// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "allonet2",
    platforms: [
        .visionOS(.v2),
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "allonet2",
            targets: ["allonet2"],
        ),
        .library(
            name: "alloclient",
            targets: ["alloclient"]
        ),
        .library(
            name: "alloheadless",
            targets: ["alloheadless"]
        ),
        .library(
            name: "AlloReality",
            targets: ["AlloReality"]
        ),
        .executable(name: "AlloPlace",
            targets: ["AlloPlace"]
        ),
        .executable(name: "demoapp",
            targets: ["demoapp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/christophhagen/BinaryCodable", from: "3.0.0"),
        //.package(url: "https://github.com/apple/swift-protobuf.git", .upToNextMajor(from: "1.25.1")),
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "125.6422.28"),
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMajor(from: "0.14.0")),
        .package(url: "https://github.com/Flight-School/AnyCodable", from: "0.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/OpenCombine/OpenCombine.git", from: "0.14.0"), // So we can use Combine on Linux.
        .package(url: "https://github.com/keyvariable/kvSIMD.swift.git", from: "1.1.0"), // So we can use simd on Linux
        .package(path: "Packages/AlloDataChannel"),
        .package(url: "https://github.com/DimaRU/PackageBuildInfo", branch: "master"),
        .package(url: "https://github.com/mxcl/Version.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "allonet2",
            dependencies: [
                "BinaryCodable",
                "AnyCodable",
                "FlyingFox",
                "Version",
                .product(name: "kvSIMD", package: "kvSIMD.swift"),
                .product(name: "OpenCombineShim", package: "opencombine"),
            ],
            plugins: [
                .plugin(name: "PackageBuildInfoPlugin", package: "PackageBuildInfo")
            ]
        ),
        .target(
            name: "alloclient",
            dependencies: [
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
                .product(name: "OpenCombineShim", package: "opencombine"),
                "allonet2"
            ]
        ),
        .target(
            name: "alloheadless",
            dependencies: [
                .product(name: "OpenCombineShim", package: "opencombine"),
                "AlloDataChannel",
                "allonet2"
            ]
        ),
        .target(
            name: "AlloReality",
            dependencies: [
                .product(name: "OpenCombineShim", package: "opencombine"),
                "alloclient",
            ]
        ),
        .testTarget(
            name: "allonet2Tests",
            dependencies: ["allonet2"]
        ),
        .executableTarget(
            name: "AlloPlace",
            dependencies: [
                "alloheadless",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "demoapp",
            dependencies: ["alloheadless"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
