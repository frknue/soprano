import AppKit
import Testing
@testable import SopranoAgents

/// The selection highlight of rendered prose, drawn by the real text view offscreen.
@MainActor
struct MarkdownSelectionTests {
    private static let markdown = """
    The changes are committed and pushed to `main` on `frknue/soprano_agents` as `ee46362` ("feat: make omp the only agent; remove Codex and Claude Code"). The push went straight to `main`, with no separate branch or PR.

    The commit has all 113 changed and deleted files from this session; the tree was clean when I started. The last `swift test` run passed (452 tests).
    """

    /// Pixel rows (top to bottom) where the selected render differs from the unselected one.
    private static func highlightedRows(_ view: MarkdownTextView, selection: NSRange) throws -> (rows: Set<Int>, scale: CGFloat) {
        func render() throws -> NSBitmapImageRep {
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let plain = try render()
        view.setSelectedRange(selection)
        let selected = try render()
        var rows = Set<Int>()
        for y in 0..<selected.pixelsHigh {
            let changed = (0..<selected.pixelsWide).filter { selected.colorAt(x: $0, y: y) != plain.colorAt(x: $0, y: y) }.count
            if changed > selected.pixelsWide / 8 { rows.insert(y) }
        }
        return (rows, CGFloat(selected.pixelsHigh) / view.bounds.height)
    }

    @Test func aMultiLineSelectionCoversTheGlyphsOfEveryLineAndNotTheGapsBetween() throws {
        _ = NSApplication.shared
        guard case let .text(text) = try #require(MarkdownRenderer.render(Self.markdown, style: .assistant).pieces.first).segment else {
            Issue.record("expected prose")
            return
        }
        let width: CGFloat = 640
        let view = MarkdownTextView()
        view.setText(text)
        view.setWidth(width, height: TextMeasure.height(text, width: width))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: view.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.applyColors(PaletteCenter.shared.palette, quoteColor: .clear)

        let (rows, scale) = try Self.highlightedRows(view, selection: NSRange(location: 1, length: text.length - 1))

        // Each line's glyph box, from its baseline, in view points.
        let layout = view.markdownLayoutManager
        var glyphBoxes: [ClosedRange<CGFloat>] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: try #require(view.textContainer))) { fragment, _, _, glyphs, _ in
            let font = text.attribute(.font, at: layout.characterIndexForGlyph(at: glyphs.location), effectiveRange: nil) as! NSFont
            let baseline = fragment.minY + layout.location(forGlyphAt: glyphs.location).y
            glyphBoxes.append((baseline - font.ascender)...(baseline - font.descender))
        }
        #expect(glyphBoxes.count == 5)
        let outside = rows.filter { row in
            let y = (CGFloat(row) + 0.5) / scale
            return !glyphBoxes.contains { ($0.lowerBound - 2)...($0.upperBound + 2) ~= y }
        }
        #expect(outside.isEmpty, "highlight drawn between lines")
        for (index, box) in glyphBoxes.enumerated() {
            let middle = Int(((box.lowerBound + box.upperBound) / 2 * scale).rounded(.down))
            #expect(rows.contains(middle), "line \(index + 1) is not highlighted")
        }
    }
}
