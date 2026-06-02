// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "DS4Control",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/textual", .upToNextMinor(from: "0.3.1"))
    ],
    targets: [
        .executableTarget(
            name: "DS4Control",
            dependencies: [
                .product(name: "Textual", package: "textual")
            ],
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
    ],
    swiftLanguageModes: [.v6]
)
