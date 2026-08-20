// swift-tools-version: 6.1
// 6.1 rather than 6.0 because swift-crypto 4.5's own manifest is 6.1: a 6.0 toolchain fails to
// resolve it, so declaring 6.0 here would promise support we don't have.
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

#if canImport(Darwin)
// AVFoundation capture/playout and the demo that uses it. Declared only on Apple hosts so
// the Linux server build never sees them.
let applePlatformTargets: [Target] = [
    .target(name: "AlloAudio", dependencies: ["allonet2"]),
    .executableTarget(name: "voicedemo", dependencies: ["alloheadless", "AlloAudio", "AlloOpus"]),
]
let applePlatformProducts: [Product] = [
    .library(name: "AlloAudio", targets: ["AlloAudio"]),
    .executable(name: "voicedemo", targets: ["voicedemo"]),
]
#else
let applePlatformTargets: [Target] = []
let applePlatformProducts: [Product] = []
#endif

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
        .library(
            name: "AlloOpus",
            targets: ["AlloOpus"]
        ),
        .executable(name: "AlloPlace",
            targets: ["AlloPlace"]
        ),
        .executable(name: "demoapp",
            targets: ["demoapp"]
        )
    ] + applePlatformProducts,
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
                "allonet2",
                "AlloAudio"
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
                "AlloAudio",
            ]
        ),
        // Vendored libopus (BSD-3). Built from source rather than linked from the system so
        // macOS, visionOS and Linux all get the same codec with no per-machine setup.
        // Architecture-specific kernels are excluded; the generic C path is far more than
        // fast enough for one 32 kbit/s mono stream.
        .target(
            name: "COpus",
            path: "Packages/opus",
            exclude: [
                "celt/arm", "celt/dump_modes", "celt/mips", "celt/tests", "celt/x86",
                "silk/arm", "silk/fixed", "silk/mips", "silk/tests", "silk/x86",
                // Demos carry their own main() and need CUSTOM_MODES, which we do not build.
                "src/opus_demo.c", "src/repacketizer_demo.c", "src/opus_compare.c",
                "celt/opus_custom_demo.c",
                "doc", "tests", "training", "win32", "cmake", "m4", "meson", "scripts",
                "include/meson.build", "celt/meson.build", "silk/meson.build", "src/meson.build",
                "CMakeLists.txt", "Makefile.am", "Makefile.mips", "Makefile.unix", "configure.ac",
                "meson.build", "meson_options.txt", "autogen.sh", "opus.m4", "opus.pc.in",
                "opus-uninstalled.pc.in", "update_version", "releases.sha2",
                "celt_headers.mk", "celt_sources.mk", "opus_headers.mk", "opus_sources.mk",
                "silk_headers.mk", "silk_sources.mk",
                "AUTHORS", "COPYING", "ChangeLog", "NEWS", "README", "README.draft",
                "LICENSE_PLEASE_READ.txt",
            ],
            sources: ["celt", "silk", "silk/float", "src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),
                .headerSearchPath("include"),
                .define("OPUS_BUILD", to: "1"),
                .define("USE_ALLOCA", to: "1"),
                .define("HAVE_LRINT", to: "1"),
                .define("HAVE_LRINTF", to: "1"),
                .define("FLOATING_POINT", to: "1"),
                .define("PACKAGE_VERSION", to: "\"1.4\""),
            ]
        ),
        // opus_encoder_ctl is a C variadic, which Swift cannot call.
        .target(name: "COpusShim", dependencies: ["COpus"]),
        .target(name: "AlloOpus", dependencies: ["COpus", "COpusShim", "allonet2"]),
        // CoreAudio capture and playout. Apple platforms only, so it is declared only when
        // building on one - the Linux server has no use for a microphone.
    ] + applePlatformTargets + [
        .testTarget(
            name: "allonet2Tests",
            dependencies: [
                "allonet2",
                "alloheadless",
                "FlyingFox",
                .product(name: "FlyingSocks", package: "FlyingFox") // reading back an ephemeral port
            ]
        ),
        .testTarget(
            name: "AlloOpusTests",
            dependencies: ["AlloOpus", "allonet2"]
        ),
        // End-to-end: a real PlaceServer and real clients over real libdatachannel loopback.
        .testTarget(
            name: "alloheadlessTests",
            dependencies: ["alloheadless", "allonet2"]
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
