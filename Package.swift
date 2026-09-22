// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "alauncher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "alauncher", targets: ["alauncher"]),
    ],
    dependencies: [
        .package(path: "Packages/Calc"),
        .package(path: "Packages/Search"),
        .package(url: "https://github.com/dduan/TOMLDecoder", exact: "0.4.5"),
        // Pinned to a main commit: the last tag (v0.9.1, January 2026) predates the
        // NemoTextProcessing trait, which is switched off to skip an unused binary.
        .package(
            url: "https://github.com/FluidInference/FluidAudio",
            revision: "fbc1b867a59a223f1b55cbc8fb20df7e1bdf7859",
            traits: []
        ),
    ],
    targets: [
        .target(
            name: "Core",
            dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]
        ),
        .target(name: "Overlay"),
        .target(
            name: "Dictation",
            dependencies: ["Core", "Overlay", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .target(
            name: "Launcher",
            dependencies: [
                "Core", "Overlay",
                .product(name: "Calc", package: "Calc"),
                .product(name: "Search", package: "Search"),
            ]
        ),
        .target(name: "Windows", dependencies: ["Core", "Overlay"]),
        .executableTarget(
            name: "alauncher",
            dependencies: ["Core", "Overlay", "Dictation", "Launcher", "Windows"]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "DictationTests",
            dependencies: ["Dictation"]
        ),
        .testTarget(
            name: "LauncherTests",
            dependencies: ["Launcher"]
        ),
        .testTarget(
            name: "WindowsTests",
            dependencies: ["Windows"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
