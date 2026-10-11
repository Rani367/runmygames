// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RunMyGames",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "rmg", targets: ["rmg"]),
        .executable(name: "RunMyGames", targets: ["RunMyGames"]),
    ],
    targets: [
        .target(name: "RMGCore"),
        .executableTarget(name: "rmg", dependencies: ["RMGCore"]),
        .executableTarget(name: "RunMyGames", dependencies: ["RMGCore"]),
        .testTarget(name: "RMGCoreTests", dependencies: ["RMGCore"], resources: [.copy("Fixtures")]),
    ]
)
