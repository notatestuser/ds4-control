// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DS4Control",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DS4Control",
            path: "Sources/DS4Control",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedLibrary("IOReport"),  // private dyld-cache lib for power/freq (Apple Silicon)
            ]
        ),
        .testTarget(
            name: "DS4ControlTests",
            dependencies: ["DS4Control"],
            path: "Tests/DS4ControlTests"
        ),
    ]
)
