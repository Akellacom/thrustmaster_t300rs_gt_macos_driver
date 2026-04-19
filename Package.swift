// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThrustmasterWheel",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CUSBModeSwitch",
            path: "Sources/CUSBModeSwitch",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "ETS2FFCore",
            path: "Sources/ETS2FFCore"
        ),
        .executableTarget(
            name: "ThrustmasterWheel",
            dependencies: ["CUSBModeSwitch", "ETS2FFCore"],
            path: "Sources/ThrustmasterWheel",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "ETS2FFControl",
            dependencies: ["ETS2FFCore"],
            path: "Sources/ETS2FFControl",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)
