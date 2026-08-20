// swift-tools-version: 6.1
// 6.1 rather than 6.0 because swift-crypto 4.5's own manifest is 6.1: a 6.0 toolchain fails to
// resolve it, so declaring 6.0 here would promise support we don't have.
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
          .package(url: "https://github.com/outfoxx/PotentCodables.git", from: "3.5.3"),

        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "137.7151.07"),
        // 0.26.0 introduced HTTPHeaders, which the asset endpoint uses. Our own Package.resolved
        // pins something newer, so nothing here catches a build that honours the lower bound —
        // KojaApp resolved 0.25.0 and failed to compile allonet2.
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMajor(from: "0.26.0")),

        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/alloverse/OpenCombine.git", branch: "fix/vision-support"), // So we can use Combine on Linux.
        .package(url: "https://github.com/keyvariable/kvSIMD.swift.git", from: "1.1.0"), // So we can use simd on Linux
        .package(url: "https://github.com/alloverse/simd-tools", branch: "main"),
        .package(path: "Packages/AlloDataChannel"),
        .package(url: "https://github.com/DimaRU/PackageBuildInfo", branch: "master"),
        .package(url: "https://github.com/mxcl/Version.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.6.0"),
        // SHA-256 for content-addressed assets. On Apple platforms `Crypto` is a CryptoKit
        // re-export, so the BoringSSL build cost is Linux-only. Pinned to the minor: the Docker
        // image is Swift 6.1.2 and swift-crypto 4.5 is already tools-version 6.1.
        .package(url: "https://github.com/apple/swift-crypto.git", .upToNextMinor(from: "4.5.1")),
        // Runtime glTF -> RealityKit, for `Model.mesh == .asset`. An xcframework binaryTarget with
        // Apple-only slices; pinned exactly, since a binary drop can change behaviour without
        // changing an API. MIT.
        .package(url: "https://github.com/warrenm/GLTFKit2.git", exact: "0.5.15"),
    ],
    targets: [
        .target(
            name: "allonet2",
            dependencies: [
                "PotentCodables",
                "FlyingFox",
                "Version",
                .product(name: "kvSIMD", package: "kvSIMD.swift"),
                .product(name: "SIMDTools", package:"simd-tools"),
                .product(name: "OpenCombineShim", package: "opencombine"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto")
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
                .product(name: "GLTFKit2", package: "GLTFKit2"),
            ]
        ),
        .testTarget(
            name: "allonet2Tests",
            dependencies: [
                "allonet2",
                "alloheadless",
                "FlyingFox",
                .product(name: "FlyingSocks", package: "FlyingFox") // reading back an ephemeral port
            ]
        ),
        // RealityKit, so Darwin-only: SwiftPM would happily try to build this on Linux and fail.
        // What saves CI is the Dockerfile asking for `--product AlloPlace`, which pulls in neither
        // this nor AlloReality. The merge gate runs the tests on macOS.
        .testTarget(
            name: "AlloRealityTests",
            dependencies: ["AlloReality"]
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
