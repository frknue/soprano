import AppKit
import Testing
@testable import Soprano

/// Guards the editor gutter's right hairline. AppKit hands a ruler dirty
/// rects that reach past its bounds and does not clip the view for it, so the
/// hairline must stay inside the gutter instead of drawing up over the file
/// toolbar and the pane header.
@MainActor
struct GutterRulerTests {
    @Test func theGutterHairlineNeverPaintsOutsideTheRuler() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GutterRulerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("long.txt")
        let text = (1...40).map { "line \($0)" }.joined(separator: "\n")
        try Data(text.utf8).write(to: fileURL)

        let document = EditorDocument(url: fileURL)
        let layoutManager = NSLayoutManager()
        document.textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: 2000))
        layoutManager.addTextContainer(container)
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            textContainer: container
        )

        let ruler = EditorLineNumberRuler(textView: textView, document: document)
        ruler.colors = ThemeManager(themeId: "gruvbox-dark").currentTheme.colors
        ruler.updateThickness()
        ruler.frame = NSRect(x: 0, y: 100, width: ruler.ruleThickness, height: 200)

        let harness = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        harness.addSubview(textView)
        harness.addSubview(ruler)

        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 60,
            pixelsHigh: 500,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // A marker colour everywhere the ruler must not reach.
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 60, height: 500).fill()
        context.cgContext.translateBy(x: 0, y: 100)
        // The dirty rect AppKit delivered when the hairline escaped: far above
        // and below the ruler's own bounds.
        ruler.draw(NSRect(x: 0, y: -150, width: ruler.ruleThickness, height: 500))
        NSGraphicsContext.restoreGraphicsState()

        let hairlineColumn = Int(ruler.ruleThickness) - 1
        func isMarker(_ row: Int) -> Bool {
            let color = bitmap.colorAt(x: hairlineColumn, y: row) ?? .clear
            return color.redComponent > 0.9 && color.greenComponent < 0.2
        }
        // The ruler occupies rows 200..<400; above and below stay the marker.
        #expect((0..<200).allSatisfy(isMarker))
        #expect((400..<500).allSatisfy(isMarker))
        #expect(!isMarker(300))
    }
}
