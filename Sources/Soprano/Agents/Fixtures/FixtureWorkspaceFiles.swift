import AppKit
import SopranoAgentsCore

/// Canned working-directory files for the snapshot harness: the demo app's repository tree
/// (matching `DemoFixtures.sampleDiff`) with readable sources. Never touches the disk.
struct FixtureWorkspaceFiles: WorkspaceFileService {
    static let paths: [String] = [
        ".gitignore",
        "Package.swift",
        "README.md",
        "Resources/AppIcon.png",
        "Sources/App/AppDelegate.swift",
        "Sources/App/main.swift",
        "Sources/Auth/AuthError.swift",
        "Sources/Auth/LoginController.swift",
        "Sources/Auth/OAuthCallback.swift",
        "Sources/Auth/SessionStore.swift",
        "Sources/Dashboard/DashboardView.swift",
        "Sources/Dashboard/DashboardViewModel.swift",
        "Sources/Networking/APIClient.swift",
        "Sources/Networking/Endpoint.swift",
        "Sources/Routing/DeepLink.swift",
        "Sources/Routing/Router.swift",
        "Sources/Settings/AppearanceSection.swift",
        "Tests/AuthTests/LoginRedirectTests.swift",
        "Tests/AuthTests/SessionStoreTests.swift",
        "Tests/RoutingTests/RouterTests.swift",
        "docs/architecture.md",
        "docs/guides/authentication.md",
        "docs/guides/deep-links.md",
        "docs/images/login-flow.png",
        "scripts/bootstrap.sh",
    ].sorted()

    func listFiles(root: String) async throws -> [String] {
        Self.paths
    }

    func readFile(root: String, relativePath: String) async throws -> WorkspaceFileContent {
        guard Self.paths.contains(relativePath) else {
            throw EngineError.message("\(relativePath) doesn't exist.")
        }
        if relativePath.hasSuffix(".png") { return .image(Self.samplePNG) }
        return .text(Self.texts[relativePath] ?? Self.placeholderSource(relativePath))
    }

    /// A small swift file for paths without hand-written contents.
    private static func placeholderSource(_ path: String) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if path.hasSuffix(".md") {
            return "# \(name.replacingOccurrences(of: "-", with: " ").capitalized)\n\nSee [the architecture overview](../architecture.md).\n"
        }
        return """
        import Foundation

        /// \(name) of the demo app.
        final class \(name) {
            init() {}
        }

        """
    }

    /// A 96 × 96 app-icon-like PNG, rendered once.
    private static let samplePNG: Data = {
        let size = 96
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        NSGradient(starting: NSColor(srgbRed: 0.32, green: 0.45, blue: 0.95, alpha: 1), ending: NSColor(srgbRed: 0.55, green: 0.33, blue: 0.86, alpha: 1))?
            .draw(in: NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 20, yRadius: 20), angle: -60)
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 30, dy: 30)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }()

    private static let texts: [String: String] = [
        ".gitignore": """
        .DS_Store
        /.build
        /Packages
        xcuserdata/
        DerivedData/
        .swiftpm/configuration/registries.json

        """,
        "Package.swift": """
        // swift-tools-version: 5.10
        import PackageDescription

        let package = Package(
            name: "App",
            platforms: [.iOS(.v17), .macOS(.v14)],
            products: [
                .library(name: "App", targets: ["App"]),
            ],
            targets: [
                .target(name: "App", path: "Sources"),
                .testTarget(name: "AuthTests", dependencies: ["App"], path: "Tests/AuthTests"),
                .testTarget(name: "RoutingTests", dependencies: ["App"], path: "Tests/RoutingTests"),
            ]
        )

        """,
        "README.md": """
        # App

        The Acme customer app: sign-in, dashboard and account settings.

        ## Getting started

        ```bash
        ./scripts/bootstrap.sh
        swift build
        swift test
        ```

        ## Layout

        - `Sources/Auth` — login, OAuth callback handling and the session cookie store.
        - `Sources/Routing` — deep links and the navigation router.
        - `Sources/Dashboard` — the home screen after sign-in.
        - `docs/` — architecture notes and guides.

        Deep links are documented in [docs/guides/deep-links.md](docs/guides/deep-links.md).

        """,
        "Sources/Auth/LoginController.swift": """
        import Foundation
        import os

        /// Drives sign-in: submits credentials, handles the OAuth callback and
        /// redirects once the session is stored.
        @MainActor
        final class LoginController {
            private let logger = Logger(subsystem: "com.acme.app", category: "login")
            private let api: APIClient
            private let router: Router
            private let sessionStore: SessionStore
            private var session: Session?

            init(api: APIClient, router: Router, sessionStore: SessionStore) {
                self.api = api
                self.router = router
                self.sessionStore = sessionStore
            }

            func signIn(email: String, password: String) async throws {
                session = try await api.send(.login(email: email, password: password))
                await redirectAfterLogin(to: .dashboard)
            }

            func redirectAfterLogin(to target: URL) async {
                guard let session else { return }
                // The dashboard reads the cookie; it must exist before we leave.
                await sessionStore.persist(session)
                logger.debug("Redirecting to \\(target, privacy: .public)")
                router.replace(with: target)
            }

            func handleCallback(_ url: URL) {
                Task {
                    await redirectAfterLogin(to: url.deepLinkTarget ?? .dashboard)
                }
            }
        }

        """,
        "Sources/Auth/SessionStore.swift": """
        import Foundation

        /// Keeps the signed-in session's cookie in the shared cookie storage.
        final class SessionStore {
            private let cookies: CookieJar

            init(cookies: CookieJar = .shared) {
                self.cookies = cookies
            }

            var hasCookie: Bool { cookies.contains(name: Session.cookieName) }

            func persist(_ session: Session) async {
                await cookies.store(session.cookie)
            }

            func clear() async {
                await cookies.remove(name: Session.cookieName)
            }
        }

        """,
        "Tests/AuthTests/LoginRedirectTests.swift": """
        import Testing
        @testable import App

        @Test func redirectWaitsForSession() async {
            let controller = LoginController.fixture()
            await controller.redirectAfterLogin(to: .dashboard)
            #expect(controller.sessionStore.hasCookie)
        }

        """,
        "docs/architecture.md": """
        # Architecture

        The app is a thin UI over three services:

        | Module | Owns |
        | --- | --- |
        | `Auth` | Credentials, OAuth callbacks, the session cookie |
        | `Routing` | Deep links and the navigation stack |
        | `Networking` | `APIClient` and typed `Endpoint`s |

        ## Sign-in flow

        ![Login flow](images/login-flow.png)

        1. `LoginController.signIn` exchanges credentials for a `Session`.
        2. `SessionStore.persist` writes the cookie **before** any redirect.
        3. `Router.replace(with:)` shows the dashboard or the deep-link target.

        """,
        "scripts/bootstrap.sh": """
        #!/usr/bin/env bash
        set -euo pipefail

        cd "$(dirname "$0")/.."
        swift package resolve
        echo "Ready. Run 'swift test' to check the setup."

        """,
    ]
}
