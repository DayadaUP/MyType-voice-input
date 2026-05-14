// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyTypeIME",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MyTypeIMEDemo", targets: ["MyTypeIMEDemo"]),
        .executable(name: "BaselineEvaluator", targets: ["BaselineEvaluator"]),
        .library(name: "IMEHost", targets: ["IMEHost"]),
        .library(name: "TextProcessor", targets: ["TextProcessor"]),
        .library(name: "Lexicon", targets: ["Lexicon"])
    ],
    targets: [
        .target(name: "Common"),
        .target(
            name: "Settings",
            dependencies: ["Common"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "Lexicon",
            dependencies: ["Common", "Settings"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(name: "TextProcessor", dependencies: ["Lexicon", "Settings"]),
        .target(
            name: "AudioEngine",
            dependencies: ["Common"],
            linkerSettings: [
                .linkedFramework("AVFoundation")
            ]
        ),
        .target(
            name: "ASRAdapter",
            dependencies: ["Common", "Settings"],
            linkerSettings: [
                .linkedFramework("AVFoundation")
            ]
        ),
        .target(
            name: "FloatingUI",
            dependencies: ["Common"],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .target(
            name: "IMEHost",
            dependencies: ["AudioEngine", "ASRAdapter", "FloatingUI", "TextProcessor", "Settings", "Lexicon"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("InputMethodKit"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .executableTarget(
            name: "MyTypeIMEDemo",
            dependencies: ["IMEHost", "TextProcessor", "Lexicon", "Settings", "Common"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("InputMethodKit")
            ]
        ),
        .executableTarget(
            name: "BaselineEvaluator",
            dependencies: ["TextProcessor", "Lexicon", "Settings"]
        ),
        .testTarget(
            name: "TextProcessorTests",
            dependencies: ["TextProcessor", "Lexicon", "Settings", "ASRAdapter", "IMEHost", "Common"]
        )
    ]
)
