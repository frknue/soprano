// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Soprano",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-markdown.git",
            exact: "0.8.0"
        ),
        // Soprano Agents' terminal drawer and right-panel terminals.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
    ],
    targets: [
        // Soprano Agents' engine: omp sessions (`omp --mode rpc-ui`), threads,
        // persistence, git checkpoints and diffs. Foundation only, no AppKit.
        .target(
            name: "SopranoAgentsCore",
            path: "Sources/SopranoAgentsCore"
        ),
        .systemLibrary(
            name: "GhosttyKit",
            path: "Sources/GhosttyKit",
            pkgConfig: nil,
            providers: nil
        ),
        .executableTarget(
            name: "Soprano",
            dependencies: [
                "GhosttyKit",
                "SopranoAgentsCore",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/Soprano",
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/SopranoCopyMode.conf"),
                .copy("Resources/SopranoOpenCodePlugin.js"),
                .copy("Resources/SopranoOpenCode"),
                .copy("Resources/SopranoOpenCodeAmbient"),
                .copy("Resources/SopranoOmpExtension.js"),
                .copy("Resources/SopranoOmpAmbient.js"),
                .copy("Resources/SopranoZsh"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(Context.packageDirectory)/lib"]),
                .linkedLibrary("ghostty"),
                .linkedLibrary("c++"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "SopranoTests",
            dependencies: ["Soprano"],
            path: "Tests/SopranoTests",
            swiftSettings: [
                .unsafeFlags(["-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
                .linkedFramework("Testing"),
            ]
        ),
        .testTarget(
            name: "SopranoAgentsTests",
            dependencies: ["Soprano", "SopranoAgentsCore"],
            path: "Tests/SopranoAgentsTests",
            // Recorded provider traces, read through #filePath.
            exclude: ["Fixtures"],
            swiftSettings: [
                .unsafeFlags(["-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
                .linkedFramework("Testing"),
            ]
        ),
    ]
)
