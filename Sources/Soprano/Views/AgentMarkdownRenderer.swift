import AppKit
import Markdown

/// Renders the Markdown an agent writes into attributed text for the dashboard timeline.
///
/// The timeline shows replies in a native text view, so Markdown becomes
/// attributes instead of HTML. Raw HTML stays visible as source text: agent
/// output echoes untrusted repository content and is never interpreted.
/// Main-actor isolated because syntax colors come from `EditorPaneView`.
@MainActor
enum AgentMarkdownRenderer {
    static func render(_ markdown: String, colors: ThemeColors, fontSize: CGFloat = 11) -> NSAttributedString {
        let renderer = Renderer(colors: colors, fontSize: fontSize)
        let root = Context(
            indent: 0,
            lead: NSAttributedString(),
            firstIndent: nil,
            firstLead: nil,
            color: colors.textPrimary,
            spacing: fontSize * 0.6
        )
        renderer.renderBlocks(Array(Document(parsing: markdown).children), in: root)
        let output = renderer.output
        if output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }
}

/// Where a block sits: list markers and quote bars are literal leading text
/// (so they survive copying), and wrapped lines hang past them.
private struct Context {
    /// Left edge of every paragraph after the first one this context emits.
    var indent: CGFloat
    /// Leading text repeated on every paragraph (quote bars).
    var lead: NSAttributedString
    /// A list item's first paragraph starts at its own edge with its marker;
    /// only the first block of the item receives it.
    var firstIndent: CGFloat?
    var firstLead: NSAttributedString?
    var color: NSColor
    var spacing: CGFloat

    /// The context for every block after the first one.
    var continuation: Context {
        var context = self
        context.firstIndent = nil
        context.firstLead = nil
        return context
    }

    var leadingIndent: CGFloat { firstIndent ?? indent }
    var leadingText: NSAttributedString { firstLead ?? lead }
}

private struct InlineStyle {
    var color: NSColor
    var size: CGFloat
    var bold = false
    var oblique = false
    var strikethrough = false
    var background: NSColor?
    var link: Any?
}

@MainActor
private struct Renderer {
    let colors: ThemeColors
    let fontSize: CGFloat
    let output = NSMutableAttributedString()

    private let bar = "▎ "

    init(colors: ThemeColors, fontSize: CGFloat) {
        self.colors = colors
        self.fontSize = fontSize
    }

    // MARK: Blocks

    func renderBlocks(_ blocks: [Markup], in context: Context) {
        for (index, block) in blocks.enumerated() {
            renderBlock(block, in: index == 0 ? context : context.continuation)
        }
    }

    func renderBlock(_ block: Markup, in context: Context) {
        switch block {
        case let paragraph as Paragraph:
            renderTextBlock(in: context, style: baseStyle(context)) { renderer, style in
                renderer.appendInlines(of: paragraph, style: style, to: renderer.output)
            }
        case let heading as Heading:
            var style = baseStyle(context)
            style.bold = true
            if heading.level <= 2 {
                style.size = fontSize + 2
            }
            let spacingBefore = output.length > 0 ? fontSize * 0.6 : 0
            renderTextBlock(in: context, style: style, spacingBefore: spacingBefore) { renderer, style in
                renderer.appendInlines(of: heading, style: style, to: renderer.output)
            }
        case let codeBlock as CodeBlock:
            renderCodeBlock(codeBlock, in: context)
        case let list as UnorderedList:
            renderList(Array(list.listItems), markers: nil, in: context)
        case let list as OrderedList:
            let start = Int(list.startIndex)
            let count = list.childCount
            let markers = (0..<count).map { "\(start + $0)." }
            let width = markers.map(\.count).max() ?? 0
            let padded = markers.map { String(repeating: " ", count: width - $0.count) + $0 }
            renderList(Array(list.listItems), markers: padded, in: context)
        case let quote as BlockQuote:
            renderQuote(quote, in: context)
        case let html as HTMLBlock:
            let source = trimmingTrailingNewlines(html.rawHTML)
            renderTextBlock(in: context, style: baseStyle(context)) { renderer, style in
                renderer.output.append(NSAttributedString(string: source, attributes: renderer.attributes(style)))
            }
        case is ThematicBreak:
            var style = baseStyle(context)
            style.color = colors.textMuted
            let rule = String(repeating: "─", count: 120)
            renderTextBlock(in: context, style: style, lineBreakMode: .byClipping) { renderer, style in
                renderer.output.append(NSAttributedString(string: rule, attributes: renderer.attributes(style)))
            }
        case let table as Table:
            renderTable(table, in: context)
        default:
            let children = Array(block.children)
            if children.allSatisfy({ $0 is BlockMarkup }) {
                renderBlocks(children, in: context)
            } else {
                renderTextBlock(in: context, style: baseStyle(context)) { renderer, style in
                    renderer.appendInlines(of: block, style: style, to: renderer.output)
                }
            }
        }
    }

    /// Emits one paragraph (hard breaks may split it into several lines that
    /// keep its hanging indent) preceded by the context's leading text.
    private func renderTextBlock(
        in context: Context,
        style: InlineStyle,
        spacingBefore: CGFloat = 0,
        lineBreakMode: NSLineBreakMode = .byWordWrapping,
        content: (Renderer, InlineStyle) -> Void
    ) {
        let start = output.length
        let lead = context.leadingText
        output.append(lead)
        content(self, style)
        output.append(NSAttributedString(string: "\n", attributes: attributes(style)))
        let firstIndent = context.leadingIndent
        applyParagraphStyle(
            NSRange(location: start, length: output.length - start),
            firstIndent: firstIndent,
            headIndent: firstIndent + lead.size().width,
            spacingBefore: spacingBefore,
            spacingAfter: context.spacing,
            lineBreakMode: lineBreakMode
        )
    }

    private func renderList(_ items: [ListItem], markers: [String]?, in context: Context) {
        let itemSpacing = fontSize * 0.25
        for (index, item) in items.enumerated() {
            let parent = index == 0 ? context : context.continuation
            let box: String? = switch item.checkbox {
            case .checked?: "☑"
            case .unchecked?: "☐"
            case nil: nil
            }
            let marker = switch (markers, box) {
            case let (markers?, box?): "\(markers[index]) \(box)"
            case let (markers?, nil): markers[index]
            case let (nil, box?): box
            case (nil, nil): "•"
            }
            let markerText = NSAttributedString(string: marker + " ", attributes: attributes(baseStyle(parent)))
            let firstLead = NSMutableAttributedString(attributedString: parent.leadingText)
            firstLead.append(markerText)

            var itemContext = parent
            itemContext.firstIndent = parent.leadingIndent
            itemContext.firstLead = firstLead
            itemContext.spacing = itemSpacing
            if parent.lead.length == 0 {
                itemContext.indent = parent.indent + markerText.size().width
            } else {
                let lead = NSMutableAttributedString(attributedString: parent.lead)
                lead.append(NSAttributedString(
                    string: String(repeating: " ", count: markerText.length),
                    attributes: attributes(baseStyle(parent))
                ))
                itemContext.lead = lead
            }

            let children = Array(item.children)
            if children.isEmpty {
                renderTextBlock(in: itemContext, style: baseStyle(itemContext)) { _, _ in }
            } else {
                renderBlocks(children, in: itemContext)
            }
        }
        restoreTrailingSpacing(context.spacing)
    }

    private func renderQuote(_ quote: BlockQuote, in context: Context) {
        var style = baseStyle(context)
        style.color = colors.textMuted
        let barText = NSAttributedString(string: bar, attributes: attributes(style))
        let isTopLevel = context.lead.length == 0 && context.firstLead == nil
        let inset = isTopLevel ? NSAttributedString(string: " ", attributes: attributes(style)).size().width : 0

        var quoteContext = context
        quoteContext.color = colors.textMuted
        quoteContext.indent = context.indent + inset
        let lead = NSMutableAttributedString(attributedString: context.lead)
        lead.append(barText)
        quoteContext.lead = lead
        if let firstLead = context.firstLead {
            let combined = NSMutableAttributedString(attributedString: firstLead)
            combined.append(barText)
            quoteContext.firstLead = combined
        }
        renderBlocks(Array(quote.children), in: quoteContext)
    }

    private func renderCodeBlock(_ codeBlock: CodeBlock, in context: Context) {
        if context.firstLead != nil {
            renderTextBlock(in: context, style: baseStyle(context)) { _, _ in }
        }
        var code = codeBlock.code
        if code.hasSuffix("\n") {
            code.removeLast()
        }
        let languageName = codeBlock.language?
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
        let language = languageName.flatMap { CodeLanguage.named($0) }

        let start = output.length
        let font = ChromeFont.monospaced(size: fontSize)
        output.append(NSAttributedString(
            string: code,
            attributes: [.font: font, .foregroundColor: colors.textPrimary]
        ))
        if let language {
            let length = (code as NSString).length
            for token in CodeSyntaxHighlighter.tokens(in: code, language: language)
            where NSMaxRange(token.range) <= length {
                output.addAttribute(
                    .foregroundColor,
                    value: EditorPaneView.color(for: token.kind, in: colors),
                    range: NSRange(location: start + token.range.location, length: token.range.length)
                )
            }
        }
        output.append(NSAttributedString(string: "\n", attributes: [.font: font]))

        let block = NSTextBlock()
        block.backgroundColor = colors.bgRaised
        // Without an explicit width TextKit sizes the block to its narrowest
        // content, which stacks a long code line one character per line.
        block.setValue(100, type: .percentageValueType, for: .width)
        block.setWidth(8, type: .absoluteValueType, for: .padding)
        block.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        block.setWidth(context.spacing, type: .absoluteValueType, for: .margin, edge: .maxY)
        applyParagraphStyle(
            NSRange(location: start, length: output.length - start),
            firstIndent: 0,
            headIndent: 0,
            spacingBefore: 0,
            spacingAfter: 0,
            lineBreakMode: .byWordWrapping,
            textBlocks: [block]
        )
    }

    private func renderTable(_ table: Table, in context: Context) {
        var headerStyle = baseStyle(context)
        headerStyle.bold = true
        let bodyStyle = baseStyle(context)
        var mutedStyle = bodyStyle
        mutedStyle.color = colors.textMuted

        let header: [NSAttributedString] = table.head.cells.map { cell -> NSAttributedString in
            let text = NSMutableAttributedString()
            appendInlines(of: cell, style: headerStyle, to: text)
            return text
        }
        let rows: [[NSAttributedString]] = table.body.rows.map { row in
            row.cells.map { cell -> NSAttributedString in
                let text = NSMutableAttributedString()
                appendInlines(of: cell, style: bodyStyle, to: text)
                return text
            }
        }
        let alignments = table.columnAlignments
        let columnCount = rows.reduce(max(alignments.count, header.count)) { max($0, $1.count) }
        guard columnCount > 0 else { return }
        var widths = [Int](repeating: 0, count: columnCount)
        for row in [header] + rows {
            for (column, cell) in row.enumerated() {
                widths[column] = max(widths[column], cell.string.count)
            }
        }

        let separator = NSAttributedString(string: " │ ", attributes: attributes(mutedStyle))
        func line(_ cells: [NSAttributedString], style: InlineStyle) -> NSAttributedString {
            let line = NSMutableAttributedString()
            for column in 0..<columnCount {
                if column > 0 {
                    line.append(separator)
                }
                let cell = column < cells.count ? cells[column] : NSAttributedString()
                let padding = widths[column] - cell.string.count
                let alignment = column < alignments.count ? alignments[column] : nil
                let leading: Int
                switch alignment {
                case .right?: leading = padding
                case .center?: leading = padding / 2
                case .left?, nil: leading = 0
                }
                let space = attributes(style)
                line.append(NSAttributedString(string: String(repeating: " ", count: leading), attributes: space))
                line.append(cell)
                line.append(NSAttributedString(
                    string: String(repeating: " ", count: padding - leading),
                    attributes: space
                ))
            }
            return line
        }

        let start = output.length
        let lead = context.leadingText
        output.append(lead)
        output.append(line(header, style: headerStyle))
        output.append(NSAttributedString(string: "\n", attributes: attributes(bodyStyle)))
        let rule = widths.map { String(repeating: "─", count: $0) }.joined(separator: "─┼─")
        output.append(NSAttributedString(string: rule + "\n", attributes: attributes(mutedStyle)))
        for row in rows {
            output.append(line(row, style: bodyStyle))
            output.append(NSAttributedString(string: "\n", attributes: attributes(bodyStyle)))
        }
        let firstIndent = context.leadingIndent
        applyParagraphStyle(
            NSRange(location: start, length: output.length - start),
            firstIndent: firstIndent,
            headIndent: firstIndent + lead.size().width,
            spacingBefore: 0,
            spacingAfter: context.spacing,
            lineBreakMode: .byWordWrapping
        )
    }

    /// Lines inside one block (hard breaks, raw HTML, table rows, code) sit
    /// tight; spacing goes only before the first and after the last.
    private func applyParagraphStyle(
        _ range: NSRange,
        firstIndent: CGFloat,
        headIndent: CGFloat,
        spacingBefore: CGFloat,
        spacingAfter: CGFloat,
        lineBreakMode: NSLineBreakMode,
        textBlocks: [NSTextBlock] = []
    ) {
        let string = output.string as NSString
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            let paragraph = NSIntersectionRange(
                string.paragraphRange(for: NSRange(location: location, length: 0)),
                range
            )
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = location == range.location ? firstIndent : headIndent
            style.headIndent = headIndent
            style.paragraphSpacingBefore = location == range.location ? spacingBefore : 0
            style.paragraphSpacing = NSMaxRange(paragraph) >= end ? spacingAfter : 0
            style.lineBreakMode = lineBreakMode
            style.textBlocks = textBlocks
            output.addAttribute(.paragraphStyle, value: style, range: paragraph)
            location = NSMaxRange(paragraph)
        }
    }

    /// List items sit tight; the list as a whole is spaced like its parent.
    private func restoreTrailingSpacing(_ spacing: CGFloat) {
        guard output.length > 0 else { return }
        let string = output.string as NSString
        let last = string.paragraphRange(for: NSRange(location: output.length - 1, length: 0))
        guard let current = output.attribute(.paragraphStyle, at: last.location, effectiveRange: nil)
            as? NSParagraphStyle,
            current.textBlocks.isEmpty,
            let style = current.mutableCopy() as? NSMutableParagraphStyle
        else { return }
        style.paragraphSpacing = spacing
        output.addAttribute(.paragraphStyle, value: style, range: last)
    }

    // MARK: Inlines

    private func appendInlines(of markup: Markup, style: InlineStyle, to target: NSMutableAttributedString) {
        for child in markup.children {
            appendInline(child, style: style, to: target)
        }
    }

    private func appendInline(_ markup: Markup, style: InlineStyle, to target: NSMutableAttributedString) {
        switch markup {
        case let text as Text:
            target.append(NSAttributedString(string: text.string, attributes: attributes(style)))
        case let strong as Strong:
            var inner = style
            inner.bold = true
            appendInlines(of: strong, style: inner, to: target)
        case let emphasis as Emphasis:
            var inner = style
            inner.oblique = true
            appendInlines(of: emphasis, style: inner, to: target)
        case let strikethrough as Strikethrough:
            var inner = style
            inner.strikethrough = true
            appendInlines(of: strikethrough, style: inner, to: target)
        case let code as InlineCode:
            var inner = style
            inner.color = colors.accentStrong
            inner.background = colors.bgRaised
            target.append(NSAttributedString(string: code.code, attributes: attributes(inner)))
        case let link as Link:
            var inner = style
            if let destination = link.destination, !destination.isEmpty {
                inner.link = URL(string: destination) ?? destination
            }
            appendInlines(of: link, style: inner, to: target)
        case let image as Image:
            var inner = style
            inner.color = colors.textMuted
            target.append(NSAttributedString(string: "[image: \(image.plainText)]", attributes: attributes(inner)))
        case let html as InlineHTML:
            target.append(NSAttributedString(string: html.rawHTML, attributes: attributes(style)))
        case is SoftBreak:
            target.append(NSAttributedString(string: " ", attributes: attributes(style)))
        case is LineBreak:
            target.append(NSAttributedString(string: "\n", attributes: attributes(style)))
        case let symbol as SymbolLink:
            var inner = style
            inner.color = colors.accentStrong
            inner.background = colors.bgRaised
            target.append(NSAttributedString(string: symbol.destination ?? "", attributes: attributes(inner)))
        default:
            if markup.childCount > 0 {
                appendInlines(of: markup, style: style, to: target)
            } else if let plain = markup as? PlainTextConvertibleMarkup {
                target.append(NSAttributedString(string: plain.plainText, attributes: attributes(style)))
            }
        }
    }

    // MARK: Attributes

    private func baseStyle(_ context: Context) -> InlineStyle {
        InlineStyle(color: context.color, size: fontSize)
    }

    private func attributes(_ style: InlineStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: ChromeFont.monospaced(size: style.size, weight: style.bold ? .bold : .regular),
            .foregroundColor: style.color,
        ]
        if style.oblique {
            attributes[.obliqueness] = 0.15
        }
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let background = style.background {
            attributes[.backgroundColor] = background
        }
        if let link = style.link {
            attributes[.link] = link
            attributes[.foregroundColor] = colors.blue
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    private func trimmingTrailingNewlines(_ text: String) -> String {
        var text = text
        while text.hasSuffix("\n") {
            text.removeLast()
        }
        return text
    }
}
