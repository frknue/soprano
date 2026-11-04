import AppKit
import Testing
@testable import Soprano

struct HexColorTests {
    private func components(_ hex: String) -> [Int] {
        let color = NSColor.fromHex(hex).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            .map { Int(($0 * 255).rounded()) }
    }

    @Test func shortAndAlphaHexColorsAreReadLikeCSSInsteadOfFallingBackToWhite() {
        #expect(components("#ff8019") == [255, 128, 25, 255])
        #expect(components("#f81") == [255, 136, 17, 255])
        #expect(components("ff801980") == [255, 128, 25, 128])
        #expect(components("#ff80") == [255, 255, 255, 255])
        #expect(components("#+f8019") == [255, 255, 255, 255])
    }
}
