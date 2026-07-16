// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TypeWiser",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "TypeWiserCore"),
        .executableTarget(
            name: "TypeWiserApp",
            dependencies: ["TypeWiserCore"]
        ),
        .testTarget(
            name: "TypeWiserCoreTests",
            dependencies: ["TypeWiserCore"]
        ),
    ]
)
