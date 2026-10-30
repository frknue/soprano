import AppKit

extension NSAttributedString.Key {
    /// Inline code: the layout manager draws a rounded `foreground 10%` chip behind it.
    static let timelineInlineCode = NSAttributedString.Key("SopranoAgents.timelineInlineCode")
    /// Block quotes: x positions (from the text's left edge) of the 2 pt quote rules of a paragraph.
    static let timelineQuoteRules = NSAttributedString.Key("SopranoAgents.timelineQuoteRules")
}

/// How a piece of Markdown is set: the chat's assistant prose (14 pt, line height 1.625,
/// `foreground 90%`), a user bubble, a plan.
struct MarkdownStyle: Hashable {
    var fontSize: CGFloat = Typography.bodySize
    var lineHeightMultiple: CGFloat = 1.625
    /// Text color as a fraction of `foreground` (T3 Code's `text-foreground/90`).
    var foregroundAlpha: CGFloat = 0.9
    /// User bubbles use `messageForeground`.
    var usesMessageForeground = false
    /// Soft line breaks become hard ones (user messages).
    var lineBreaks = false

    static let assistant = MarkdownStyle()
    static let user = MarkdownStyle(foregroundAlpha: 1, usesMessageForeground: true, lineBreaks: true)
    static let plan = MarkdownStyle(foregroundAlpha: 1)
    static let thought = MarkdownStyle(foregroundAlpha: 0.8, lineBreaks: true)
}

/// A rendered table: attributed cells plus alignment.
struct MarkdownTableRendering {
    var alignments: [NSTextAlignment]
    var header: [NSAttributedString]
    var rows: [[NSAttributedString]]
    var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }
}

/// A vertical piece of rendered Markdown. Prose (paragraphs, headings, lists, quotes) flows in
/// one attributed string; code blocks, tables and rules are their own views.
enum MarkdownSegment {
    case text(NSAttributedString)
    case code(language: String?, code: String, highlighted: NSAttributedString, indent: CGFloat)
    case table(MarkdownTableRendering, indent: CGFloat)
    case rule(indent: CGFloat)

    /// Text a find searches in this segment.
    var searchableText: String {
        switch self {
        case let .text(text): text.string
        case let .code(_, code, _, _): code
        case let .table(table, _):
            (table.header + table.rows.flatMap { $0 }).map(\.string).joined(separator: "\n")
        case .rule: ""
        }
    }
}

/// Rendered Markdown: segments with the space above each one (collapsed CSS block margins).
final class MarkdownRendering {
    struct Piece {
        var segment: MarkdownSegment
        var spacingBefore: CGFloat
    }

    let pieces: [Piece]
    let style: MarkdownStyle

    init(pieces: [Piece], style: MarkdownStyle) {
        self.pieces = pieces
        self.style = style
    }

    var searchableTexts: [String] { pieces.map(\.segment.searchableText) }
    var plainText: String { pieces.map(\.segment.searchableText).filter { !$0.isEmpty }.joined(separator: "\n\n") }
}

/// Block model → attributed segments, colored from the palette (T3 Code's `.chat-markdown` CSS).
/// Results are cached per text and style; the cache empties when the palette changes.
@MainActor
enum MarkdownRenderer {
    private struct Key: Hashable {
        var text: String
        var style: MarkdownStyle
    }

    private static var cache: [Key: MarkdownRendering] = [:]
    private static var cachedPalette: Palette?

    static func render(_ text: String, style: MarkdownStyle) -> MarkdownRendering {
        let palette = PaletteCenter.shared.palette
        if cachedPalette != palette {
            cache.removeAll()
            cachedPalette = palette
        }
        let key = Key(text: text, style: style)
        if let cached = cache[key] { return cached }
        if cache.count > 600 { cache.removeAll() }
        var builder = Builder(style: style, palette: palette)
        builder.renderBlocks(MarkdownDocument.parse(text, lineBreaks: style.lineBreaks), context: Builder.Context())
        let rendering = MarkdownRendering(pieces: builder.finish(), style: style)
        cache[key] = rendering
        return rendering
    }

    /// Syntax colors for code, mapped onto palette tokens.
    static func syntaxColor(_ kind: SyntaxTokenKind, palette: Palette) -> NSColor {
        switch kind {
        case .keyword, .tag: palette.mergedForeground
        case .heading: palette.foreground
        case .string, .inserted: palette.successForeground
        case .comment: palette.mutedForeground
        case .number, .attribute: palette.warningForeground
        case .type: palette.infoForeground
        case .function, .key: palette.infoForeground
        case .deleted: palette.errorForeground
        }
    }

    /// Highlighted code in SF Mono 13 (`--font-size-code`), line height 1.375 (`leading-snug`).
    static func highlightedCode(_ code: String, language: String?, palette: Palette, fontSize: CGFloat = Typography.codeSize) -> NSAttributedString {
        let font = Typography.mono(fontSize)
        let paragraph = NSMutableParagraphStyle()
        let lineHeight = (fontSize * 1.375).rounded()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byCharWrapping
        let result = NSMutableAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: palette.foreground,
            .paragraphStyle: paragraph,
            .baselineOffset: (lineHeight - font.ascender + font.descender) / 4,
        ])
        if let name = language, let language = CodeLanguage.named(name) {
            for token in CodeSyntaxHighlighter.tokens(in: code, language: language)
            where NSMaxRange(token.range) <= result.length {
                result.addAttribute(.foregroundColor, value: syntaxColor(token.kind, palette: palette), range: token.range)
            }
        }
        return result
    }

    // MARK: - Builder

    @MainActor
    private struct Builder {
        struct Context {
            /// Left edge of the block's text.
            var indent: CGFloat = 0
            /// Quote rule positions active for this block.
            var quoteRules: [CGFloat] = []
            /// Nesting of unordered / ordered lists (marker style).
            var bulletDepth = 0
            var orderedDepth = 0
            /// Inside a list item: paragraphs use the item's tight spacing.
            var tightSpacing: CGFloat?
            /// Heading level shift (none for now; kept for user headings).
            var color: NSColor?
        }

        let style: MarkdownStyle
        let palette: Palette
        var pieces: [MarkdownRendering.Piece] = []
        var text = NSMutableAttributedString()
        /// Margin owed below the last block (collapses with the next block's top margin).
        var pendingMargin: CGFloat = 0
        /// Margin before the current text segment's first paragraph.
        var textSegmentSpacing: CGFloat = 0
        var isFirstBlock = true

        init(style: MarkdownStyle, palette: Palette) {
            self.style = style
            self.palette = palette
        }

        var bodyColor: NSColor {
            (style.usesMessageForeground ? palette.messageForeground : palette.foreground).timelineAlpha(style.foregroundAlpha)
        }

        var blockMargin: CGFloat { (style.fontSize * 0.65 / 0.875).rounded() } // 0.65rem at 14 pt prose ≈ 10

        // MARK: Blocks

        mutating func renderBlocks(_ blocks: [MarkdownBlock], context: Context) {
            for block in blocks { render(block, context: context) }
        }

        mutating func render(_ block: MarkdownBlock, context: Context) {
            switch block {
            case let .paragraph(inlines):
                let margin = context.tightSpacing ?? blockMargin
                appendParagraph(inlines: inlines, font: Typography.ui(style.fontSize), color: context.color ?? bodyColor,
                                lineHeight: style.fontSize * style.lineHeightMultiple, top: margin, bottom: margin, context: context)
            case let .heading(level, inlines):
                let size: CGFloat = switch level {
                case 1: style.fontSize + 6
                case 2: style.fontSize + 4
                case 3: style.fontSize + 2
                default: style.fontSize
                }
                let color = level == 6 ? palette.mutedForeground : palette.foreground
                appendParagraph(inlines: inlines, font: Typography.ui(size, weight: .semibold), color: color,
                                lineHeight: (size * 1.3).rounded(), top: 20, bottom: 8, context: context)
            case let .list(ordered, start, items):
                renderList(ordered: ordered, start: start, items: items, context: context)
            case let .blockquote(blocks):
                var inner = context
                inner.quoteRules.append(context.indent)
                inner.indent = context.indent + 2 + 12.8
                let before = pendingMargin
                pendingMargin = max(before, blockMargin)
                renderBlocks(blocks, context: inner)
                pendingMargin = max(pendingMargin, blockMargin)
            case let .code(language, code):
                flushText()
                let highlighted = MarkdownRenderer.highlightedCode(code, language: language, palette: palette)
                appendSegment(.code(language: language, code: code, highlighted: highlighted, indent: context.indent), top: blockMargin, bottom: blockMargin)
            case let .table(table):
                flushText()
                appendSegment(.table(renderTable(table), indent: context.indent), top: blockMargin, bottom: blockMargin)
            case .thematicBreak:
                flushText()
                appendSegment(.rule(indent: context.indent), top: 16, bottom: 16)
            case let .html(source):
                appendParagraph(inlines: [.text(source)], font: Typography.ui(style.fontSize), color: context.color ?? bodyColor,
                                lineHeight: style.fontSize * style.lineHeightMultiple, top: blockMargin, bottom: blockMargin, context: context)
            }
        }

        mutating func renderList(ordered: Bool, start: Int, items: [MarkdownListItem], context: Context) {
            let gutter: CGFloat = 20
            let font = Typography.ui(style.fontSize)
            let listMargin = context.tightSpacing != nil ? 4 : blockMargin
            pendingMargin = max(pendingMargin, listMargin)
            for (index, item) in items.enumerated() {
                var inner = context
                inner.indent = context.indent + gutter
                inner.tightSpacing = 4
                if ordered { inner.orderedDepth += 1 } else { inner.bulletDepth += 1 }
                let marker: Marker
                if let checked = item.checkbox {
                    marker = .checkbox(checked)
                } else if ordered {
                    marker = .text(orderedMarker(start + index, depth: context.orderedDepth))
                } else {
                    marker = .text(["•", "◦", "▪"][min(context.bulletDepth, 2)])
                }
                if index > 0 { pendingMargin = max(pendingMargin, 4) }
                var first = true
                for block in item.blocks {
                    if first, case .paragraph = block {
                        pendingMarker = (marker, context.indent, font)
                    } else if first {
                        // A list item that opens with a non-paragraph still shows its marker.
                        appendParagraph(inlines: [], font: font, color: bodyColor, lineHeight: style.fontSize * style.lineHeightMultiple,
                                        top: 4, bottom: 0, context: inner, marker: (marker, context.indent, font))
                    }
                    render(block, context: inner)
                    first = false
                }
                if item.blocks.isEmpty {
                    appendParagraph(inlines: [], font: font, color: bodyColor, lineHeight: style.fontSize * style.lineHeightMultiple,
                                    top: 4, bottom: 0, context: inner, marker: (marker, context.indent, font))
                }
            }
            pendingMargin = max(pendingMargin, listMargin)
        }

        enum Marker {
            case text(String)
            case checkbox(Bool)
        }

        var pendingMarker: (Marker, CGFloat, NSFont)?

        func orderedMarker(_ number: Int, depth: Int) -> String {
            switch depth % 3 {
            case 1:
                var value = max(1, number)
                var letters = ""
                while value > 0 {
                    value -= 1
                    letters = String(UnicodeScalar(UInt8(97 + value % 26))) + letters
                    value /= 26
                }
                return letters + "."
            case 2:
                return roman(number).lowercased() + "."
            default:
                return "\(number)."
            }
        }

        func roman(_ number: Int) -> String {
            let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
            var value = max(1, number)
            var result = ""
            for (amount, letters) in table {
                while value >= amount {
                    result += letters
                    value -= amount
                }
            }
            return result
        }

        // MARK: Paragraphs

        mutating func appendParagraph(
            inlines: [MarkdownInline],
            font: NSFont,
            color: NSColor,
            lineHeight: CGFloat,
            top: CGFloat,
            bottom: CGFloat,
            context: Context,
            marker explicitMarker: (Marker, CGFloat, NSFont)? = nil
        ) {
            let spacing = max(pendingMargin, top)
            let marker = explicitMarker ?? pendingMarker
            pendingMarker = nil
            let start = text.length
            let paragraphSpacing: CGFloat
            if text.length == 0 {
                textSegmentSpacing = isFirstBlock && pieces.isEmpty ? 0 : spacing
                paragraphSpacing = 0
            } else {
                text.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                paragraphSpacing = spacing
            }
            isFirstBlock = false
            let paragraphStart = text.length
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            paragraph.paragraphSpacingBefore = paragraphSpacing
            paragraph.firstLineHeadIndent = context.indent
            paragraph.headIndent = context.indent
            paragraph.lineBreakMode = .byWordWrapping
            let baseline = (lineHeight - (font.ascender - font.descender)) / 4
            if let (marker, edge, markerFont) = marker {
                paragraph.firstLineHeadIndent = edge
                paragraph.tabStops = [
                    NSTextTab(textAlignment: .right, location: context.indent - 6),
                    NSTextTab(textAlignment: .left, location: context.indent),
                ]
                switch marker {
                case let .text(value):
                    let markerColor = value.count == 1 ? color.timelineAlpha(0.6) : color
                    text.append(NSAttributedString(string: "\t\(value)\t", attributes: [
                        .font: value.count == 1 ? markerFont : Typography.tabular(markerFont.pointSize),
                        .foregroundColor: markerColor,
                        .baselineOffset: baseline,
                    ]))
                case let .checkbox(checked):
                    text.append(NSAttributedString(string: "\t", attributes: [.font: markerFont]))
                    text.append(checkbox(checked, font: markerFont, baseline: baseline))
                    text.append(NSAttributedString(string: "\t", attributes: [.font: markerFont]))
                }
            }
            appendInlines(inlines, attributes: [.font: font, .foregroundColor: color, .baselineOffset: baseline], to: text)
            // The "\n" before `paragraphStart` ends the previous paragraph; it keeps that one's attributes.
            let range = NSRange(location: paragraphStart, length: text.length - paragraphStart)
            if range.length > 0 {
                text.addAttribute(.paragraphStyle, value: paragraph, range: range)
                if !context.quoteRules.isEmpty {
                    text.addAttribute(.timelineQuoteRules, value: context.quoteRules, range: range)
                }
            }
            // Consecutive paragraphs of one quote share the rule across their gap.
            if start < paragraphStart, start > 0, !context.quoteRules.isEmpty,
               (text.attribute(.timelineQuoteRules, at: start - 1, effectiveRange: nil) as? [CGFloat]) == context.quoteRules {
                text.addAttribute(.timelineQuoteRules, value: context.quoteRules, range: NSRange(location: start, length: 1))
            }
            pendingMargin = bottom
        }

        func checkbox(_ checked: Bool, font: NSFont, baseline: CGFloat) -> NSAttributedString {
            let name = checked ? "checkmark.square.fill" : "square"
            let tint = checked ? palette.primary : palette.mutedForeground
            let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize - 1, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [checked ? palette.primaryForeground : tint, tint]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: checked ? "Done" : "To do")?
                .withSymbolConfiguration(configuration) else {
                return NSAttributedString(string: checked ? "☑" : "☐", attributes: [.font: font])
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: font.descender + 1 + baseline, width: image.size.width, height: image.size.height)
            return NSAttributedString(attachment: attachment)
        }

        // MARK: Inlines

        func appendInlines(_ inlines: [MarkdownInline], attributes: [NSAttributedString.Key: Any], to output: NSMutableAttributedString) {
            for inline in inlines {
                switch inline {
                case let .text(value):
                    output.append(NSAttributedString(string: value, attributes: attributes))
                case let .emphasis(children):
                    appendInlines(children, attributes: with(attributes, trait: .italicFontMask), to: output)
                case let .strong(children):
                    appendInlines(children, attributes: withWeight(attributes, .semibold), to: output)
                case let .strikethrough(children):
                    var next = attributes
                    next[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    appendInlines(children, attributes: next, to: output)
                case let .code(value):
                    let base = attributes[.font] as? NSFont ?? Typography.ui(style.fontSize)
                    var next = attributes
                    next[.font] = Typography.mono((base.pointSize * 0.85).rounded(), weight: base.fontDescriptor.symbolicTraits.contains(.bold) ? .semibold : .regular)
                    next[.foregroundColor] = palette.foreground
                    next[.timelineInlineCode] = true
                    // Room for the chip's horizontal padding (0.35em each side).
                    if output.length > 0 {
                        let last = NSRange(location: output.length - 1, length: 1)
                        if (output.attribute(.timelineInlineCode, at: last.location, effectiveRange: nil) as? Bool) != true {
                            output.addAttribute(.kern, value: 4, range: last)
                        }
                    }
                    let code = NSMutableAttributedString(string: value, attributes: next)
                    if code.length > 0 {
                        code.addAttribute(.kern, value: 4, range: NSRange(location: code.length - 1, length: 1))
                    }
                    output.append(code)
                case let .link(destination, children):
                    var next = attributes
                    if let destination, let url = URL(string: destination) {
                        next[.link] = url
                    }
                    next[.foregroundColor] = palette.infoForeground
                    appendInlines(children, attributes: next, to: output)
                case let .image(_, alt):
                    output.append(NSAttributedString(string: alt, attributes: attributes))
                case .softBreak:
                    output.append(NSAttributedString(string: " ", attributes: attributes))
                case .lineBreak:
                    output.append(NSAttributedString(string: "\u{2028}", attributes: attributes))
                case let .html(source):
                    output.append(NSAttributedString(string: source, attributes: attributes))
                }
            }
        }

        func with(_ attributes: [NSAttributedString.Key: Any], trait: NSFontTraitMask) -> [NSAttributedString.Key: Any] {
            var next = attributes
            if let font = attributes[.font] as? NSFont {
                next[.font] = NSFontManager.shared.convert(font, toHaveTrait: trait)
            }
            return next
        }

        func withWeight(_ attributes: [NSAttributedString.Key: Any], _ weight: NSFont.Weight) -> [NSAttributedString.Key: Any] {
            var next = attributes
            if let font = attributes[.font] as? NSFont {
                let italic = font.fontDescriptor.symbolicTraits.contains(.italic)
                var bold = font.fontDescriptor.symbolicTraits.contains(.monoSpace)
                    ? Typography.mono(font.pointSize, weight: weight)
                    : Typography.ui(font.pointSize, weight: weight)
                if italic { bold = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask) }
                next[.font] = bold
            }
            return next
        }

        // MARK: Tables

        func renderTable(_ table: MarkdownTable) -> MarkdownTableRendering {
            let font = Typography.ui(style.fontSize)
            let lineHeight = (style.fontSize * style.lineHeightMultiple).rounded()
            func cell(_ inlines: [MarkdownInline], header: Bool, alignment: NSTextAlignment) -> NSAttributedString {
                let output = NSMutableAttributedString()
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = lineHeight
                paragraph.maximumLineHeight = lineHeight
                paragraph.alignment = alignment
                paragraph.lineBreakMode = .byWordWrapping
                let cellFont = header ? Typography.ui(style.fontSize, weight: .semibold) : font
                let baseline = (lineHeight - (cellFont.ascender - cellFont.descender)) / 4
                appendInlines(inlines, attributes: [.font: cellFont, .foregroundColor: header ? palette.foreground : bodyColor, .baselineOffset: baseline], to: output)
                output.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: output.length))
                return output
            }
            let alignments: [NSTextAlignment] = table.alignments.map { alignment in
                switch alignment {
                case .center?: .center
                case .right?: .right
                default: .natural
                }
            }
            func alignment(_ column: Int) -> NSTextAlignment { column < alignments.count ? alignments[column] : .natural }
            return MarkdownTableRendering(
                alignments: alignments,
                header: table.header.enumerated().map { cell($1, header: true, alignment: alignment($0)) },
                rows: table.rows.map { row in row.enumerated().map { cell($1, header: false, alignment: alignment($0)) } }
            )
        }

        // MARK: Segments

        mutating func flushText() {
            guard text.length > 0 else { return }
            pieces.append(MarkdownRendering.Piece(segment: .text(text), spacingBefore: textSegmentSpacing))
            text = NSMutableAttributedString()
        }

        mutating func appendSegment(_ segment: MarkdownSegment, top: CGFloat, bottom: CGFloat) {
            let spacing = pieces.isEmpty && isFirstBlock ? 0 : max(pendingMargin, top)
            isFirstBlock = false
            pieces.append(MarkdownRendering.Piece(segment: segment, spacingBefore: spacing))
            pendingMargin = bottom
        }

        mutating func finish() -> [MarkdownRendering.Piece] {
            flushText()
            return pieces
        }
    }
}
