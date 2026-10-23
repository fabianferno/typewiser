// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TypeWiser",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Auto-update for the notarized release build. See RELEASING.md.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: [
        .target(
            name: "TypeWiserCore",
            // FoundationModels only exists on macOS 26+. Weak-link it so the app
            // still launches on macOS 15, where `OnDeviceRewriter` falls back to
            // its rules — a strong link would crash at load before any
            // `#available` check could run.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])]
        ),
        .executableTarget(
            name: "TypeWiserApp",
            dependencies: ["TypeWiserCore", .product(name: "Sparkle", package: "Sparkle")],
            // `bundle-app.sh` copies Sparkle.framework into Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
