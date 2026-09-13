// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Calc",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Calc", targets: ["Calc"]),
    ],
    targets: [
        .target(name: "Calc"),
        .testTarget(name: "CalcTests", dependencies: ["Calc"], resources: [.copy("Fixtures")]),
    ]
)
