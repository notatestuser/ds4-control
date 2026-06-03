// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "DS4Control",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Fork of Lakr233/MarkdownView (battle-tested in FlowDown), branched off the 3.9.1 revision
        // FlowDown ships, with two DS4 patches on the `ds4-patches` branch: (1) code blocks reserve
        // their actual rendered height so they no longer overlap following text; (2) emphasis renders
        // as italic instead of an orange underline. Pinned by revision for reproducible signed builds.
        // Upstream: https://github.com/Lakr233/MarkdownView — re-base the patches when bumping.
        .package(
            url: "https://github.com/notatestuser/MarkdownView",
            revision: "d83032f91844e5365f49a174d9940036790e434c"),
    ],
    targets: [
        .executableTarget(
            name: "DS4Control",
            dependencies: [
                .product(name: "MarkdownView", package: "MarkdownView"),
                .product(name: "MarkdownParser", package: "MarkdownView"),
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
