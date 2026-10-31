import AppKit
import SopranoAgentsCore

/// The provider mark: omp's "π", a template image (tint with `contentTintColor`).
@MainActor
enum ProviderGlyph {
    /// The mark at `size` points.
    static func image(for kind: ProviderKind, size: CGFloat = 14) -> NSImage {
        let key = "\(kind.rawValue)-\(size)-\(PaletteCenter.shared.palette.isDark)"
        if let cached = cache[key] { return cached }
        let image = renderPi(size: size)
        image.isTemplate = true
        image.accessibilityDescription = kind.displayName
        cache[key] = image
        return image
    }

    private static var cache: [String: NSImage] = [:]

    /// omp (oh-my-pi) has no vector mark: a bold "π" set in the system font, template-rendered.
    private static func renderPi(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let font = NSFont.systemFont(ofSize: size * 1.05, weight: .heavy)
            let text = NSAttributedString(string: "π", attributes: [.font: font, .foregroundColor: NSColor.black])
            let bounds = text.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
            text.draw(at: NSPoint(x: (rect.width - bounds.width) / 2, y: (rect.height - bounds.height) / 2 - size * 0.06))
            return true
        }
    }
}
