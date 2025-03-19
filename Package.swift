// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "allonet2",
    platforms: [
        .visionOS(.v2),
        .macOS(.v12),
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
            name: "AlloReality",
            type: .dynamic,
            targets: ["AlloReality"]
        ),
        .executable(name: "server",
            targets: ["server"]
        ),
        .executable(name: "democlient",
            targets: ["democlient"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/christophhagen/BinaryCodable", from: "3.0.0"),
        //.package(url: "https://github.com/apple/swift-protobuf.git", .upToNextMajor(from: "1.25.1")),
        .package(url: "https://github.com/stasel/WebRTC.git", .upToNextMajor(from: "123.0.0")),
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMajor(from: "0.14.0")),
        .package(url: "https://github.com/Flight-School/AnyCodable", from: "0.6.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "allonet2",
            dependencies: ["WebRTC", "BinaryCodable", "AnyCodable", "FlyingFox"]
        ),
        .target(
            name: "AlloReality",
            dependencies: ["allonet2"]
        ),
        .testTarget(
            name: "allonet2Tests",
            dependencies: ["allonet2"]
        ),
        .executableTarget(
            name: "server",
            dependencies: ["allonet2"]
        ),
        .executableTarget(
            name: "democlient",
            dependencies: ["allonet2"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
