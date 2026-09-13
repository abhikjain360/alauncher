// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Search",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Search", targets: ["Search"]),
    ],
    targets: [
        .target(name: "Search"),
        .testTarget(
            name: "SearchTests",
            dependencies: ["Search"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
