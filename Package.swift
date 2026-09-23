// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeensInKey",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KeensInKey", targets: ["KeensInKey"]),
        .executable(name: "kik", targets: ["kik"]),
        .library(name: "KeensInKeyCore", targets: ["KeensInKeyCore"]),
    ],
    targets: [
        .target(
            name: "KeensInKeyCore",
            path: "Sources/KeensInKeyCore"
        ),
        .executableTarget(
            name: "KeensInKey",
            dependencies: ["KeensInKeyCore"],
            path: "Sources/KeensInKey"
        ),
        .executableTarget(
            name: "kik",
            dependencies: ["KeensInKeyCore"],
            path: "Sources/kik"
        ),
        .testTarget(
            name: "KeensInKeyCoreTests",
            dependencies: ["KeensInKeyCore"],
            path: "Tests/KeensInKeyCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
