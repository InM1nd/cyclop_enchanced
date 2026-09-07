// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cyclop",
    // macOS 15 for Translation.framework, which the translate tab runs on.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Cyclop", targets: ["Cyclop"]),
        .library(name: "CyclopLogic", targets: ["CyclopLogic"]),
    ],
    targets: [
        .target(
            name: "CyclopLogic",
            path: "Sources/CyclopLogic",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Cyclop",
            dependencies: ["CyclopLogic"],
            path: "Sources/Cyclop",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CyclopLogicCheck",
            dependencies: ["CyclopLogic"],
            path: "Sources/CyclopLogicCheck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
