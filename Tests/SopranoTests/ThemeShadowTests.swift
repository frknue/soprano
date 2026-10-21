import AppKit
import Testing
@testable import Soprano

/// Elevation shadows fall below the surface on screen, whether the layer
/// tree is y-up or geometry-flipped (a flipped NSView's backing layer).
@MainActor
struct ThemeShadowTests {
    @Test func theShadowCastsDownInAYUpTree() throws {
        let rendered = try render(flip: .none)
        #expect(rendered.below > 0.5)
        #expect(rendered.above < 0.05)
    }

    @Test func theShadowCastsDownUnderAGeometryFlippedHost() throws {
        let rendered = try render(flip: .host)
        #expect(rendered.below > 0.5)
        #expect(rendered.above < 0.05)
    }

    @Test func theShadowCastsDownFromAGeometryFlippedSurface() throws {
        let rendered = try render(flip: .surface)
        #expect(rendered.below > 0.5)
        #expect(rendered.above < 0.05)
    }

    private enum Flip {
        case none
        case host
        case surface
    }

    /// Renders an opaque 40 pt square with a hard 20 pt black shadow at the
    /// centre of a 100 pt white host (inside a plain root, since a rendered
    /// root's own flip is not applied) and returns the shadow's coverage just
    /// below and just above the square, as seen on screen.
    private func render(flip: Flip) throws -> (below: CGFloat, above: CGFloat) {
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let host = CALayer()
        host.frame = root.bounds
        host.backgroundColor = NSColor.white.cgColor
        host.isGeometryFlipped = flip == .host
        root.addSublayer(host)
        let surface = CALayer()
        surface.frame = CGRect(x: 30, y: 30, width: 40, height: 40)
        surface.backgroundColor = NSColor.white.cgColor
        surface.isGeometryFlipped = flip == .surface
        host.addSublayer(surface)
        ThemeShadow(color: .black, opacity: 1, offsetY: 20, blur: 0, ring: .clear).apply(to: surface)

        let context = try #require(CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        root.render(in: context)
        let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        // NSBitmapImageRep rows run top-down, as the image appears on screen.
        func darkness(screenY: Int) -> CGFloat {
            1 - (bitmap.colorAt(x: 50, y: screenY)?.whiteComponent ?? 1)
        }
        return (below: darkness(screenY: 80), above: darkness(screenY: 20))
    }
}
