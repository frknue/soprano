import AppKit

/// The command token the caret is in: a word that starts a line with `/` and runs to the next
/// whitespace. Ranges are UTF-16 (`NSString`) offsets.
struct SlashToken: Equatable {
    /// The whole token, `/` included.
    let range: NSRange
    /// What was typed between the `/` and the caret.
    let query: String

    /// The token around `caret`, when the caret sits after its `/` and no further than its end.
    static func at(_ text: String, caret: Int) -> SlashToken? {
        let string = text as NSString
        guard caret > 0, caret <= string.length else { return nil }
        let whitespace = CharacterSet.whitespacesAndNewlines
        // Walk back from the caret to the start of the word.
        var start = caret
        while start > 0, let scalar = UnicodeScalar(string.character(at: start - 1)), !whitespace.contains(scalar) {
            start -= 1
        }
        guard start < caret else { return nil }
        if start > 0 {
            let before = string.character(at: start - 1)
            guard before == 0x0A || before == 0x0D else { return nil }
        }
        guard string.character(at: start) == 0x2F else { return nil }
        var end = caret
        while end < string.length, let scalar = UnicodeScalar(string.character(at: end)), !whitespace.contains(scalar) {
            end += 1
        }
        let query = string.substring(with: NSRange(location: start + 1, length: caret - start - 1))
        return SlashToken(range: NSRange(location: start, length: end - start), query: query)
    }

    /// The edit that replaces the token with `insertText`. When the inserted text ends in a space
    /// and one already follows the token, that space is replaced too, so none doubles up.
    func replacement(inserting insertText: String, in text: String) -> (range: NSRange, text: String) {
        let string = text as NSString
        var range = range
        let end = NSMaxRange(range)
        if insertText.hasSuffix(" "), end < string.length, string.character(at: end) == 0x20 {
            range.length += 1
        }
        return (range, insertText)
    }
}

/// When the `/` menu gives up because the keyboard went elsewhere.
enum SlashMenuFocus {
    /// Another of the app's windows became key (palette, dialog, settings): the editor no longer
    /// gets keys, so the menu closes. The main window (or the menu itself) becoming key does not
    /// close it, and neither does the main window merely resigning key (app deactivated, or an
    /// offscreen window that never was key): no other window is typing then.
    static func closes(whenKey keyWindow: NSWindow?, main: NSWindow?, menu: NSWindow?) -> Bool {
        guard let keyWindow else { return false }
        return keyWindow !== main && keyWindow !== menu
    }
}

/// Which commands the `/` menu shows for a typed query.
enum SlashCommandFilter {
    /// Case-insensitive: names starting with the query first, then names containing it, then
    /// descriptions containing it; each group keeps the agent's order. An empty query keeps
    /// everything.
    static func matching(_ commands: [AgentChatCommand], query: String) -> [AgentChatCommand] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return commands }
        var prefixed: [AgentChatCommand] = []
        var named: [AgentChatCommand] = []
        var described: [AgentChatCommand] = []
        for command in commands {
            let name = command.name.lowercased()
            if name.hasPrefix(needle) {
                prefixed.append(command)
            } else if name.contains(needle) {
                named.append(command)
            } else if command.description?.lowercased().contains(needle) ?? false {
                described.append(command)
            }
        }
        return prefixed + named + described
    }

    /// The muted single row when nothing can be listed.
    static func emptyText(agentName: String, hasCandidates: Bool, query: String) -> String {
        if hasCandidates { return "No commands match “/\(query)”" }
        return "No commands from \(agentName) yet — they load once the session starts."
    }
}

/// The `/` command menu: a passive floating list above the composer. The editor keeps keyboard
/// focus and forwards ↑/↓, Enter, Tab and Escape (`ComposerTextView.menuKeyHandler`).
final class SlashCommandMenuContent: ComposerPopoverContent {
    private let list = ComposerListView(maxHeight: 288, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
    private var widthConstraint: NSLayoutConstraint?
    private var shown: [AgentChatCommand] = []
    private let onPick: (AgentChatCommand) -> Void

    init(width: CGFloat, onPick: @escaping (AgentChatCommand) -> Void) {
        self.onPick = onPick
        super.init(frame: .zero)
        list.translatesAutoresizingMaskIntoConstraints = false
        addSubview(list)
        let width = widthAnchor.constraint(equalToConstant: width)
        widthConstraint = width
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.topAnchor.constraint(equalTo: topAnchor),
            list.bottomAnchor.constraint(equalTo: bottomAnchor),
            width,
        ])
        setAccessibilityRole(.list)
        setAccessibilityLabel("Commands")
    }

    func setWidth(_ width: CGFloat) {
        guard let widthConstraint, abs(widthConstraint.constant - width) > 0.5 else { return }
        widthConstraint.constant = width
        requestResize?()
    }

    /// Shows `commands`, or one muted `emptyText` row when there are none. `keepingHighlight`
    /// (a re-list for the same query) keeps the highlighted command where it still shows;
    /// otherwise the first row is highlighted.
    func show(_ commands: [AgentChatCommand], emptyText: String, keepingHighlight: Bool = false) {
        let kept = keepingHighlight ? list.highlightedIndex.flatMap { shown.indices.contains($0) ? shown[$0].insertText : nil } : nil
        shown = commands
        if commands.isEmpty {
            list.setRows([ComposerListRow.Model(title: emptyText, isDisabled: true, titleFont: Typography.ui(Typography.rowSize))], actions: [{}], highlight: nil)
        } else {
            let rows = commands.map { command in
                ComposerListRow.Model(
                    title: command.insertText.trimmingCharacters(in: .whitespaces),
                    subtitle: command.description,
                    titleNote: command.hint,
                    toolTip: command.description,
                    titleFont: Typography.ui(Typography.bodySize, weight: .medium),
                    subtitleLines: 1
                )
            }
            let actions: [() -> Void] = commands.map { command in { [weak self] in self?.onPick(command) } }
            list.setRows(rows, actions: actions, highlight: kept.flatMap { text in commands.firstIndex { $0.insertText == text } } ?? 0)
        }
        requestResize?()
    }

    func moveHighlight(by delta: Int) {
        list.moveHighlight(by: delta)
    }

    /// Picks the highlighted command. Returns false when nothing is highlighted.
    func chooseHighlighted() -> Bool {
        list.chooseHighlighted()
    }
}
