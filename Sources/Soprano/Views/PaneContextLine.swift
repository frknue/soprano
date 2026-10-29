import AppKit

/// The muted line under a pane or agent's title in the sidebar and the Agent
/// Dashboard: what the title leaves out, `omp · soprano · ⎇ feat/x · 2 tabs`.
/// A shell's title is already its folder, so a shell in its repository's
/// default branch has nothing to add and its sidebar row is one line.
struct PaneContextLine: Equatable {
    /// An agent's name, when its title is its task instead, and its folder.
    var context: [String] = []
    /// A branch other than the repository's default.
    var branch: String?
    /// The pane's tabs; only a pane with several says so.
    var tabCount = 1

    init(context: [String] = [], branch: String? = nil, tabCount: Int = 1) {
        self.context = context
        self.branch = branch
        self.tabCount = tabCount
    }

    /// The line for a pane or agent titled `title`. An agent is named when
    /// its title is something else (its task) and its folder is given; a
    /// shell's title already is its folder or command.
    init(title: String, agentName: String?, workingDirectory: String?, branch: String?, tabCount: Int = 1) {
        if let agentName {
            if title != agentName {
                context.append(agentName)
            }
            if let workingDirectory {
                context.append(TerminalTitle.folderName(workingDirectory))
            }
        }
        self.branch = branch
        self.tabCount = tabCount
    }

    var isEmpty: Bool { context.isEmpty && branch == nil && tabCount < 2 }

    /// The line in one font and color, its parts joined by ` · `, the branch
    /// led by SF Symbols' branch glyph.
    func attributed(font: NSFont, color: NSColor) -> NSAttributedString {
        var parts = context.map { ChromeText.attributed($0, font: font, color: color) }
        if let branch {
            parts.append(Self.branchText(branch, font: font, color: color))
        }
        if tabCount > 1 {
            parts.append(ChromeText.attributed("\(tabCount) tabs", font: font, color: color))
        }
        let separator = ChromeText.attributed(" · ", font: font, color: color)
        let text = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 { text.append(separator) }
            text.append(part)
        }
        return text
    }

    /// The branch glyph, drawn in the text's color and centered on its cap
    /// height, then the name.
    private static func branchText(_ branch: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize - 1, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")?
            .withSymbolConfiguration(configuration) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(
                x: 0,
                y: (font.capHeight - image.size.height) / 2,
                width: image.size.width,
                height: image.size.height
            )
            text.append(NSAttributedString(attachment: attachment))
            text.append(ChromeText.attributed(" ", font: font, color: color))
        }
        text.append(ChromeText.attributed(branch, font: font, color: color))
        return text
    }
}
