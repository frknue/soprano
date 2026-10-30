import Foundation
import Markdown

/// Inline Markdown, reduced to what the chat renders (T3 Code's `ChatMarkdown`).
indirect enum MarkdownInline: Hashable, Sendable {
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case link(destination: String?, [MarkdownInline])
    /// Images show as their alt text (agent output may point anywhere; nothing is fetched).
    case image(source: String?, alt: String)
    case softBreak
    case lineBreak
    /// Raw inline HTML stays visible as source text, never interpreted.
    case html(String)
}

struct MarkdownListItem: Hashable, Sendable {
    /// nil = no task checkbox; true = `- [x]`.
    var checkbox: Bool?
    var blocks: [MarkdownBlock]
}

struct MarkdownTable: Hashable, Sendable {
    enum Alignment: Hashable, Sendable {
        case left
        case center
        case right
    }

    var alignments: [Alignment?]
    var header: [[MarkdownInline]]
    var rows: [[[MarkdownInline]]]
}

/// Block Markdown: paragraphs, headings, lists, quotes, code, tables, rules.
indirect enum MarkdownBlock: Hashable, Sendable {
    case paragraph([MarkdownInline])
    case heading(level: Int, [MarkdownInline])
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case blockquote([MarkdownBlock])
    case code(language: String?, code: String)
    case table(MarkdownTable)
    case thematicBreak
    case html(String)
}

/// Markdown text → block model, through swift-markdown (CommonMark + GFM tables, task lists,
/// strikethrough). Pure; the renderer turns the model into attributed text and views.
enum MarkdownDocument {
    /// `lineBreaks` turns soft line breaks into hard ones (user messages keep their lines, like
    /// T3 Code's `lineBreaks` prop).
    static func parse(_ text: String, lineBreaks: Bool = false) -> [MarkdownBlock] {
        let document = Document(parsing: text)
        return blocks(of: document.children, lineBreaks: lineBreaks)
    }

    /// Text of inlines as it reads (alt text for images, breaks as newlines/spaces).
    static func plainText(of inlines: [MarkdownInline]) -> String {
        var result = ""
        for inline in inlines {
            switch inline {
            case let .text(text), let .code(text), let .html(text): result += text
            case let .emphasis(children), let .strong(children), let .strikethrough(children), let .link(_, children):
                result += plainText(of: children)
            case let .image(_, alt): result += alt
            case .softBreak: result += " "
            case .lineBreak: result += "\n"
            }
        }
        return result
    }

    /// The first heading's text, else nil (T3 Code's `proposedPlanTitle`).
    static func firstHeading(in markdown: String) -> String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            guard line.count - trimmed.count <= 3, trimmed.hasPrefix("#") else { continue }
            let hashes = trimmed.prefix { $0 == "#" }
            guard hashes.count <= 6 else { continue }
            let rest = trimmed.dropFirst(hashes.count)
            guard rest.first == " " || rest.first == "\t" else { continue }
            let title = rest.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// The plan body without its leading title heading (and a "Summary" heading right after it),
    /// like T3 Code's `stripDisplayedPlanMarkdown`.
    static func strippingTitle(_ markdown: String) -> String {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        func isHeading(_ line: String) -> Bool {
            let trimmed = line.drop { $0 == " " }
            guard line.count - trimmed.count <= 3 else { return false }
            let hashes = trimmed.prefix { $0 == "#" }
            return (1...6).contains(hashes.count) && trimmed.dropFirst(hashes.count).first == " "
        }
        func dropBlank() { while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() } }
        if let first = lines.first, isHeading(first) { lines.removeFirst() }
        dropBlank()
        if let first = lines.first, isHeading(first),
           first.drop(while: { $0 == " " || $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased() == "summary" {
            lines.removeFirst()
            dropBlank()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Conversion

    private static func blocks(of children: MarkupChildren, lineBreaks: Bool) -> [MarkdownBlock] {
        children.compactMap { block(of: $0, lineBreaks: lineBreaks) }
    }

    private static func block(of markup: Markup, lineBreaks: Bool) -> MarkdownBlock? {
        switch markup {
        case let paragraph as Paragraph:
            return .paragraph(inlines(of: paragraph.children, lineBreaks: lineBreaks))
        case let heading as Heading:
            return .heading(level: heading.level, inlines(of: heading.children, lineBreaks: lineBreaks))
        case let list as UnorderedList:
            return .list(ordered: false, start: 1, items: list.listItems.map { item(of: $0, lineBreaks: lineBreaks) })
        case let list as OrderedList:
            return .list(ordered: true, start: Int(list.startIndex), items: list.listItems.map { item(of: $0, lineBreaks: lineBreaks) })
        case let quote as BlockQuote:
            return .blockquote(blocks(of: quote.children, lineBreaks: lineBreaks))
        case let code as CodeBlock:
            var source = code.code
            if source.hasSuffix("\n") { source.removeLast() }
            let language = code.language?.trimmingCharacters(in: .whitespaces)
            return .code(language: language?.isEmpty == false ? language : nil, code: source)
        case let table as Table:
            let alignments: [MarkdownTable.Alignment?] = table.columnAlignments.map { alignment in
                switch alignment {
                case .left?: .left
                case .center?: .center
                case .right?: .right
                case nil: nil
                }
            }
            let header = table.head.cells.map { inlines(of: $0.children, lineBreaks: lineBreaks) }
            let rows = table.body.rows.map { row in Array(row.cells.map { inlines(of: $0.children, lineBreaks: lineBreaks) }) }
            return .table(MarkdownTable(alignments: alignments, header: Array(header), rows: Array(rows)))
        case is ThematicBreak:
            return .thematicBreak
        case let html as HTMLBlock:
            var raw = html.rawHTML
            while raw.hasSuffix("\n") { raw.removeLast() }
            return .html(raw)
        default:
            let children = Array(markup.children)
            if children.isEmpty { return nil }
            if children.allSatisfy({ $0 is BlockMarkup }) {
                let nested = children.compactMap { block(of: $0, lineBreaks: lineBreaks) }
                return nested.count == 1 ? nested[0] : .blockquote(nested)
            }
            return .paragraph(inlines(of: markup.children, lineBreaks: lineBreaks))
        }
    }

    private static func item(of item: ListItem, lineBreaks: Bool) -> MarkdownListItem {
        let checkbox: Bool? = switch item.checkbox {
        case .checked?: true
        case .unchecked?: false
        case nil: nil
        }
        return MarkdownListItem(checkbox: checkbox, blocks: blocks(of: item.children, lineBreaks: lineBreaks))
    }

    private static func inlines(of children: MarkupChildren, lineBreaks: Bool) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for child in children {
            let converted = inline(of: child, lineBreaks: lineBreaks)
            // Merge adjacent text runs so searching and measuring see whole words.
            if case let .text(next) = converted, case let .text(previous)? = result.last {
                result[result.count - 1] = .text(previous + next)
            } else {
                result.append(converted)
            }
        }
        return result
    }

    private static func inline(of markup: Markup, lineBreaks: Bool) -> MarkdownInline {
        switch markup {
        case let text as Text: .text(text.string)
        case let emphasis as Emphasis: .emphasis(inlines(of: emphasis.children, lineBreaks: lineBreaks))
        case let strong as Strong: .strong(inlines(of: strong.children, lineBreaks: lineBreaks))
        case let strike as Strikethrough: .strikethrough(inlines(of: strike.children, lineBreaks: lineBreaks))
        case let code as InlineCode: .code(code.code)
        case let link as Link: .link(destination: link.destination, inlines(of: link.children, lineBreaks: lineBreaks))
        case let image as Image: .image(source: image.source, alt: image.plainText)
        case let symbol as SymbolLink: .code(symbol.destination ?? "")
        case is SoftBreak: lineBreaks ? .lineBreak : .softBreak
        case is LineBreak: .lineBreak
        case let html as InlineHTML: .html(html.rawHTML)
        default:
            if markup.childCount > 0 {
                .emphasis(inlines(of: markup.children, lineBreaks: lineBreaks)).flattenedIfPlain
            } else {
                .text(markup.format())
            }
        }
    }
}

private extension MarkdownInline {
    /// Unknown containers keep their children without adding emphasis.
    var flattenedIfPlain: MarkdownInline {
        if case let .emphasis(children) = self { return .text(MarkdownDocument.plainText(of: children)) }
        return self
    }
}
