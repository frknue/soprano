// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Soprano",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "GhosttyKit",
            path: "Sources/GhosttyKit",
            pkgConfig: nil,
            providers: nil
        ),
        .executableTarget(
            name: "Soprano",
            dependencies: ["GhosttyKit"],
            path: "Sources/Soprano",
            linkerSettings: [
                .unsafeFlags(["-L\(Context.packageDirectory)/lib"]),
                .linkedLibrary("ghostty"),
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
