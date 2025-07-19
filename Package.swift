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
            type: .dynamic,
            targets: ["allonet2"]
        ),
        .library(
            name: "alloclient",
            type: .dynamic,
            targets: ["alloclient"]
        ),
        .library(
            name: "alloserver",
            type: .dynamic,
            targets: ["alloserver"]
        ),
        .library(
            name: "AlloReality",
            type: .dynamic,
            targets: ["AlloReality"]
        ),
        .executable(name: "AlloPlace",
            targets: ["AlloPlace"]
        ),
        .executable(name: "democlient",
            targets: ["democlient"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/christophhagen/BinaryCodable", from: "3.0.0"),
        //.package(url: "https://github.com/apple/swift-protobuf.git", .upToNextMajor(from: "1.25.1")),
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "125.6422.28"),
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMajor(from: "0.14.0")),
        .package(url: "https://github.com/Flight-School/AnyCodable", from: "0.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(path: "Packages/AlloDataChannel"),
    ],
    targets: [
        .target(
            name: "allonet2",
            dependencies: [
                "BinaryCodable",
                "AnyCodable",
                "FlyingFox"
            ]
        ),
        .target(
            name: "alloclient",
            dependencies: [
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
                "allonet2"
            ]
        ),
        .target(
            name: "alloserver",
            dependencies: [
                "AlloDataChannel",
                "allonet2"
            ]
        ),
        .target(
            name: "AlloReality",
            dependencies: ["alloclient"]
        ),
        .testTarget(
            name: "allonet2Tests",
            dependencies: ["allonet2"]
        ),
        .executableTarget(
            name: "AlloPlace",
            dependencies: [
                "alloserver",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "democlient",
            dependencies: ["allonet2"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
