import AppKit

extension NSColor {
    /// Create an NSColor from a CSS-style hex string: "#ff8019", "ff8019",
    /// the short form "#f81", or "#ff801980" with alpha last. Anything else
    /// is white.
    static func fromHex(_ hex: String) -> NSColor {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }
        if hexString.count == 3 {
            hexString = hexString.map { "\($0)\($0)" }.joined()
        }

        guard hexString.count == 6 || hexString.count == 8,
              hexString.allSatisfy(\.isHexDigit),
              var rgba = UInt64(hexString, radix: 16)
        else {
            return .white
        }
        if hexString.count == 6 {
            rgba = (rgba << 8) | 0xFF
        }

        let r = CGFloat((rgba >> 24) & 0xFF) / 255.0
        let g = CGFloat((rgba >> 16) & 0xFF) / 255.0
        let b = CGFloat((rgba >> 8) & 0xFF) / 255.0
        let a = CGFloat(rgba & 0xFF) / 255.0

        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
