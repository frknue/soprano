import Foundation
import Markdown

/// GitHub-flavored Markdown to HTML with all source text and attributes escaped.
///
/// `swift-markdown` deliberately preserves raw HTML nodes. A local document can
/// come from an untrusted checkout, so Soprano renders those nodes visibly as
/// source and never hands document-provided elements or scripts to WebKit.
struct MarkdownHTMLRenderer: MarkupWalker {
    private(set) var result = ""
    private var headingSlugCounts: [String: Int] = [:]
    private var tableColumnAlignments: [Table.ColumnAlignment?] = []
    private var currentTableColumn = 0
    private var isInTableHead = false

    static func render(_ source: String) -> String {
        var renderer = MarkdownHTMLRenderer()
        renderer.visit(Document(parsing: source))
        return renderer.result
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        result += "<blockquote>\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let language = codeBlock.language
            .map { " class=\"language-\(Self.escapeAttribute($0))\"" }
            ?? ""
        result += "<pre><code\(language)>\(Self.escapeText(codeBlock.code))</code></pre>\n"
    }

    mutating func visitHeading(_ heading: Heading) {
        let slug = uniqueHeadingSlug(for: heading.plainText)
        result += "<h\(heading.level) id=\"\(Self.escapeAttribute(slug))\">"
        descendInto(heading)
        result += "</h\(heading.level)>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        result += "<pre class=\"raw-html\"><code>"
        result += Self.escapeText(html.rawHTML)
        result += "</code></pre>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        result += "<li>"
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked ? " checked" : ""
            result += "<input type=\"checkbox\" disabled\(checked)> "
        }
        descendInto(listItem)
        result += "</li>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let start = orderedList.startIndex == 1
            ? ""
            : " start=\"\(orderedList.startIndex)\""
        result += "<ol\(start)>\n"
        descendInto(orderedList)
        result += "</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        result += "<ul>\n"
        descendInto(unorderedList)
        result += "</ul>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        result += "<p>"
        descendInto(paragraph)
        result += "</p>\n"
    }

    mutating func visitTable(_ table: Table) {
        let previousAlignments = tableColumnAlignments
        tableColumnAlignments = table.columnAlignments
        result += "<div class=\"table-scroll\"><table>\n"
        descendInto(table)
        result += "</table></div>\n"
        tableColumnAlignments = previousAlignments
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        isInTableHead = true
        currentTableColumn = 0
        result += "<thead><tr>\n"
        descendInto(tableHead)
        result += "</tr></thead>\n"
        isInTableHead = false
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        guard !tableBody.isEmpty else { return }
        result += "<tbody>\n"
        descendInto(tableBody)
        result += "</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        currentTableColumn = 0
        result += "<tr>\n"
        descendInto(tableRow)
        result += "</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        let element = isInTableHead ? "th" : "td"
        var attributes = ""
        if currentTableColumn < tableColumnAlignments.count,
           let alignment = tableColumnAlignments[currentTableColumn]
        {
            let value: String
            switch alignment {
            case .left:
                value = "left"
            case .center:
                value = "center"
            case .right:
                value = "right"
            }
            attributes += " class=\"align-\(value)\""
        }
        currentTableColumn += 1
        if tableCell.colspan > 1 {
            attributes += " colspan=\"\(tableCell.colspan)\""
        }
        if tableCell.rowspan > 1 {
            attributes += " rowspan=\"\(tableCell.rowspan)\""
        }
        result += "<\(element)\(attributes)>"
        descendInto(tableCell)
        result += "</\(element)>\n"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(Self.escapeText(inlineCode.code))</code>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        wrap("em", around: emphasis)
    }

    mutating func visitStrong(_ strong: Strong) {
        wrap("strong", around: strong)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        wrap("del", around: strikethrough)
    }

    mutating func visitImage(_ image: Image) {
        guard let source = image.source,
              let safeSource = Self.safeDestination(source, isImage: true)
        else {
            result += Self.escapeText(image.plainText)
            return
        }
        result += "<img src=\"\(Self.escapeAttribute(safeSource))\""
        result += " alt=\"\(Self.escapeAttribute(image.plainText))\""
        if let title = image.title, !title.isEmpty {
            result += " title=\"\(Self.escapeAttribute(title))\""
        }
        result += ">"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        result += Self.escapeText(inlineHTML.rawHTML)
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br>\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }

    mutating func visitLink(_ link: Link) {
        guard let destination = link.destination,
              let safeDestination = Self.safeDestination(destination, isImage: false)
        else {
            descendInto(link)
            return
        }
        result += "<a href=\"\(Self.escapeAttribute(safeDestination))\""
        if let title = link.title, !title.isEmpty {
            result += " title=\"\(Self.escapeAttribute(title))\""
        }
        result += ">"
        descendInto(link)
        result += "</a>"
    }

    mutating func visitText(_ text: Text) {
        result += Self.escapeText(text.string)
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
        result += "<code>\(Self.escapeText(symbolLink.destination ?? ""))</code>"
    }

    mutating func visitInlineAttributes(_ attributes: InlineAttributes) {
        // Attribute syntax must not smuggle classes or styles into the page.
    }

    private mutating func wrap(_ tag: String, around markup: Markup) {
        result += "<\(tag)>"
        descendInto(markup)
        result += "</\(tag)>"
    }

    private mutating func uniqueHeadingSlug(for text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        var slug = ""
        var needsDash = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsDash, !slug.isEmpty {
                    slug.append("-")
                }
                slug.unicodeScalars.append(scalar)
                needsDash = false
            } else {
                needsDash = true
            }
        }
        if slug.isEmpty {
            slug = "section"
        }
        let count = headingSlugCounts[slug, default: 0]
        headingSlugCounts[slug] = count + 1
        return count == 0 ? slug : "\(slug)-\(count)"
    }

    private static func safeDestination(_ value: String, isImage: Bool) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let components = URLComponents(string: trimmed) else { return nil }
        guard let scheme = components.scheme?.lowercased() else {
            return trimmed
        }
        if isImage, scheme == "data" {
            return trimmed.lowercased().hasPrefix("data:image/") ? trimmed : nil
        }
        let allowed = isImage
            ? ["https"]
            : ["http", "https", "mailto", "file", "soprano-markdown"]
        return allowed.contains(scheme) ? trimmed : nil
    }

    private static func escapeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escapeText(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
