// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "pancake",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "PancakeCore", targets: ["PancakeCore"]),
        .executable(name: "pancake", targets: ["pancake"]),
        .executable(name: "PancakeApp", targets: ["PancakeApp"]),
        .executable(name: "PancakeStage", targets: ["PancakeStage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // The realtime half: the one IOProc and the lock-free matrix it reads. Plain C so
        // nothing ARC-shaped can sneak onto the audio thread.
        .target(
            name: "CPancakeRT",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        // Everything else: CoreAudio wrappers, the graph model, the engine.
        .target(
            name: "PancakeCore",
            dependencies: ["CPancakeRT"],
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("IOBluetooth")]
        ),
        // The menu bar app. Built as a bare executable by SwiftPM; `make app` wraps it in a bundle.
        .executableTarget(
            name: "PancakeApp",
            dependencies: ["PancakeCore"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("AVFoundation")]
        ),
        .executableTarget(
            name: "pancake",
            dependencies: [
                "PancakeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // "Pancake Stage": mirrors the desktop into a shareable window and plays the Program bus
        // into itself, so Discord's window-share carries full-desktop video + clean stereo audio
        // with none of the call's own audio. See DESIGN.md § Stage.
        .executableTarget(
            name: "PancakeStage",
            dependencies: ["PancakeCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .testTarget(
            name: "PancakeCoreTests",
            dependencies: ["PancakeCore"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
