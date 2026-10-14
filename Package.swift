// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BookshelfBar",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "BookshelfBar", targets: ["BookshelfBar"]),
        .executable(name: "kefctl", targets: ["kefctl"]),
        .library(name: "KEFKit", targets: ["KEFKit"]),
    ],
    targets: [
        // Speaker control over the local HTTP API (no UI, no CoreAudio).
        .target(name: "KEFKit"),
        // CoreAudio side: finding the KEF USB device, its volume, mute and default-output state.
        .target(name: "KEFAudio"),
        // App logic shared by the UI: speaker model and Smooth Start.
        .target(name: "BookshelfBarCore", dependencies: ["KEFKit", "KEFAudio"]),
        .executableTarget(name: "BookshelfBar", dependencies: ["BookshelfBarCore"], resources: [.process("Resources")]),
        .executableTarget(name: "kefctl", dependencies: ["KEFKit", "KEFAudio"]),
        .testTarget(name: "KEFKitTests", dependencies: ["KEFKit"]),
        .testTarget(name: "KEFAudioTests", dependencies: ["KEFAudio"]),
    ]
)
