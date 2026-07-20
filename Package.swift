// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "keyboard.wtf",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KeyboardWtfCore", targets: ["KeyboardWtfCore"]),
        .executable(name: "keyboard-wtf", targets: ["KeyboardWtfApp"])
    ],
    targets: [
        .target(
            name: "KeyboardWtfCore",
            path: "Sources/KeyboardWtfCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("Speech"),
                .linkedFramework("Carbon"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "KeyboardWtfApp",
            dependencies: ["KeyboardWtfCore"],
            path: "Sources/KeyboardWtfApp",
            exclude: ["Resources"],
            linkerSettings: [.linkedFramework("SwiftUI")]
        ),
        .testTarget(
            name: "KeyboardWtfCoreTests",
            dependencies: ["KeyboardWtfCore"],
            path: "Tests/KeyboardWtfCoreTests"
        )
    ]
)
