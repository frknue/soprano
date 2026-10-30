import AppKit
import SopranoAgentsCore

/// The command token the caret is in: a word that starts a line with a sigil (`/`, or `$` for
/// Codex skills) and runs to the next whitespace. Ranges are UTF-16 (`NSString`) offsets.
struct SlashToken: Equatable {
    /// "/" or "$".
    let sigil: Character
    /// The whole token, sigil included.
    let range: NSRange
    /// What was typed between the sigil and the caret.
    let query: String

    /// The token around `caret`, when the caret sits after its sigil and no further than its end.
    static func at(_ text: String, caret: Int, sigils: Set<Character>) -> SlashToken? {
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
        guard let sigilScalar = UnicodeScalar(string.character(at: start)) else { return nil }
        let sigil = Character(sigilScalar)
        guard sigils.contains(sigil) else { return nil }
        var end = caret
        while end < string.length, let scalar = UnicodeScalar(string.character(at: end)), !whitespace.contains(scalar) {
            end += 1
        }
        let query = string.substring(with: NSRange(location: start + 1, length: caret - start - 1))
        return SlashToken(sigil: sigil, range: NSRange(location: start, length: end - start), query: query)
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
    /// The app's own `/compact` row, listed when the provider's list lacks one and the thread can compact.
    static let compactCommand = ProviderCommand(
        name: "compact",
        kind: .command,
        description: "Compact the conversation",
        source: "App",
        insertText: "/compact "
    )

    /// Commands reachable with `sigil`, plus the app's `/compact` row when `includeCompact` and
    /// the provider has none of its own.
    static func candidates(_ commands: [ProviderCommand], sigil: Character, includeCompact: Bool) -> [ProviderCommand] {
        var result = commands.filter { $0.insertText.first == sigil }
        if includeCompact, sigil == "/", !result.contains(where: { $0.insertText.trimmingCharacters(in: .whitespaces) == "/compact" }) {
            result.append(compactCommand)
        }
        return result
    }

    /// Case-insensitive: names starting with the query first, then names containing it, then
    /// descriptions containing it; each group keeps the provider's order. An empty query keeps
    /// everything.
    static func matching(_ commands: [ProviderCommand], query: String) -> [ProviderCommand] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return commands }
        var prefixed: [ProviderCommand] = []
        var named: [ProviderCommand] = []
        var described: [ProviderCommand] = []
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
    static func emptyText(provider: ProviderKind, sigil: Character, hasCandidates: Bool, query: String) -> String {
        if hasCandidates { return "No commands match “\(sigil)\(query)”" }
        let noun = sigil == "$" ? "skills" : "commands"
        return "No \(noun) from \(provider.displayName) yet — they load once the session starts."
    }
}

/// The `/` command menu: a passive floating list above the composer. The editor keeps keyboard
/// focus and forwards ↑/↓, Enter, Tab and Escape (`ComposerTextView.menuKeyHandler`).
final class SlashCommandMenuContent: ComposerPopoverContent {
    private let list = ComposerListView(maxHeight: 288, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
    private var widthConstraint: NSLayoutConstraint?
    private var shown: [ProviderCommand] = []
    private let onPick: (ProviderCommand) -> Void

    init(width: CGFloat, onPick: @escaping (ProviderCommand) -> Void) {
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

    /// Shows `commands`, or one muted `emptyText` row when there are none.
    func show(_ commands: [ProviderCommand], emptyText: String) {
        shown = commands
        if commands.isEmpty {
            list.setRows([ComposerListRow.Model(title: emptyText, isDisabled: true, titleFont: Typography.ui(Typography.rowSize))], actions: [{}], highlight: nil)
        } else {
            let rows = commands.map { command in
                ComposerListRow.Model(
                    title: command.insertText.trimmingCharacters(in: .whitespaces),
                    subtitle: command.description.flatMap { $0.isEmpty ? nil : $0 },
                    titleNote: command.argumentHint.flatMap { $0.isEmpty ? nil : $0 },
                    badge: command.source,
                    toolTip: command.description,
                    titleFont: Typography.ui(Typography.bodySize, weight: .medium),
                    subtitleLines: 1
                )
            }
            let actions: [() -> Void] = commands.map { command in { [weak self] in self?.onPick(command) } }
            list.setRows(rows, actions: actions, highlight: 0)
        }
        requestResize?()
    }

    var hasSelectableRow: Bool { list.highlightedIndex != nil }

    func moveHighlight(by delta: Int) {
        list.moveHighlight(by: delta)
    }

    /// Picks the highlighted command. Returns false when nothing is highlighted.
    func chooseHighlighted() -> Bool {
        list.chooseHighlighted()
    }
}
