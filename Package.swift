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
            dependencies: ["TypeWiserCore"],
            // `GoldenRewriteTests.swift` loads Fixtures/golden.json via #filePath,
            // relative to the source file on disk — not via Bundle.module — so this
            // is excluded rather than declared as a `resources:` copy (which would be
            // dead: nothing ever reads it via Bundle.module).
            exclude: ["Fixtures"]
        ),
    ]
)
