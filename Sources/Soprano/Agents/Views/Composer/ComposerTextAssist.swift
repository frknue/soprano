import AppKit
import SopranoAgentsCore

/// Ghost-text word completion in the composer, as omp's terminal composer has it: the provider
/// predicts the rest of the word before the caret (`AgentEngine.predictWord`) on every edit
/// while the caret ends its line; Tab accepts it with a space, → without. Typing that still
/// matches the ghost keeps showing the rest of it until the provider answers; typing past it
/// (diverging) or accepting is reported to the provider so it learns.
@MainActor
final class ComposerWordCompletion {
    private struct Shown {
        /// The editor's text and caret the suggestion was made for.
        var text: String
        var cursor: Int
        var suggestion: String
    }

    private weak var textView: ComposerTextView?
    private let engine: AgentEngine
    /// The provider of the thread or draft being typed.
    var provider: () -> ProviderKind = { .omp }
    /// True while something else owns the keys after the caret (the `/` menu).
    var isSuppressed: () -> Bool = { false }
    /// The provider's `wordCompletion` preference.
    var isEnabled = false {
        didSet { if !isEnabled { clear() } }
    }

    private var shown: Shown?
    private var request: Task<Void, Never>?
    /// The ghost's rest when the edit about to land types into it.
    private var projection: String?
    private var isAccepting = false

    init(textView: ComposerTextView, engine: AgentEngine) {
        self.textView = textView
        self.engine = engine
        textView.onAcceptGhost = { [weak self] space in self?.accept(space: space) ?? false }
        textView.onWillChangeText = { [weak self] range, text in self?.willChange(range, text) }
    }

    /// The caret where a word completion may show: nothing selected, a letter before it, and
    /// nothing after it on its line. nil otherwise.
    nonisolated static func cursor(in text: NSString, selection: NSRange) -> Int? {
        let cursor = selection.location
        guard selection.length == 0, cursor > 0, cursor <= text.length else { return nil }
        if cursor < text.length, !CharacterSet.newlines.contains(UnicodeScalar(text.character(at: cursor)) ?? " ") { return nil }
        let before = text.rangeOfComposedCharacterSequence(at: cursor - 1)
        return text.substring(with: before).unicodeScalars.allSatisfy(CharacterSet.letters.contains) ? cursor : nil
    }

    /// The editor's text changed: show the projected rest at once, then ask the provider.
    func textChanged() {
        let projected = projection
        projection = nil
        request?.cancel()
        request = nil
        guard isEnabled, !isSuppressed(), let textView, !textView.isSettingText, !textView.hasMarkedText(),
              let cursor = Self.cursor(in: textView.string as NSString, selection: textView.selectedRange()) else {
            clear()
            return
        }
        let text = textView.string
        show(projected, text: text, cursor: cursor)
        let provider = provider()
        request = Task { [weak self, engine] in
            let suffix = await engine.predictWord(provider, text: text, cursor: cursor)
            // A late answer never shows once the editor lost focus or the text or caret moved on.
            guard let self, !Task.isCancelled, let suffix, let textView = self.textView,
                  textView.window?.firstResponder === textView,
                  textView.string == text, textView.selectedRange() == NSRange(location: cursor, length: 0) else { return }
            self.show(suffix, text: text, cursor: cursor)
        }
    }

    /// The caret moved without an edit: a ghost no longer at the caret goes.
    func selectionChanged() {
        guard let shown, let textView, textView.string == shown.text else { return }
        if textView.selectedRange() != NSRange(location: shown.cursor, length: 0) { clear() }
    }

    func clear() {
        request?.cancel()
        request = nil
        shown = nil
        textView?.ghostText = nil
    }

    private func show(_ suggestion: String?, text: String, cursor: Int) {
        shown = suggestion.map { Shown(text: text, cursor: cursor, suggestion: $0) }
        textView?.ghostText = suggestion
    }

    private func accept(space: Bool) -> Bool {
        guard let shown, let textView, textView.ghostText == shown.suggestion, textView.string == shown.text,
              textView.selectedRange() == NSRange(location: shown.cursor, length: 0) else { return false }
        engine.reportWordCompletion(provider(), text: shown.text, cursor: shown.cursor, suggestion: shown.suggestion, accepted: true)
        isAccepting = true
        defer { isAccepting = false }
        textView.insertText(space ? shown.suggestion + " " : shown.suggestion, replacementRange: textView.selectedRange())
        return true
    }

    /// Typing at the caret either follows the ghost (its rest keeps showing) or diverges from it
    /// (reported as typed past).
    private func willChange(_ range: NSRange, _ typed: String) {
        guard !isAccepting, let shown, !typed.isEmpty, range == NSRange(location: shown.cursor, length: 0) else { return }
        let ghost = shown.suggestion
        if ghost.lowercased().hasPrefix(typed.lowercased()) {
            if typed.count < ghost.count { projection = String(ghost.dropFirst(typed.count)) }
            return
        }
        let overlap = min(ghost.count, typed.count)
        guard ghost.prefix(overlap).lowercased() != typed.prefix(overlap).lowercased() else { return }
        engine.reportWordCompletion(provider(), text: shown.text, cursor: shown.cursor, suggestion: ghost, accepted: false)
    }
}

/// Which composer text keeps spelling and grammar marks: prose, not code. Skipped like omp's
/// terminal prose gate: inline `code`, ``` and ~~~ fences, and any word that reads as code or a
/// reference (paths, file names, identifiers with `_` or inner capitals, flags, `/commands`,
/// `@mentions`, URLs, anything with digits). Markdown emphasis (`*word*`, `**word**`) is prose.
enum ComposerProse {
    /// Trimmed off a word's start before judging it.
    private static let leadingPunctuation = CharacterSet(charactersIn: "\"'“‘(*")
    /// Trimmed off a word's end before judging it.
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?…\"'”’)*")
    private static let codeCharacters = CharacterSet(charactersIn: "/\\._=<>{}[]()|`:~$#@&%+^")
    private static let codeStarts = CharacterSet(charactersIn: "-/@#$~")

    /// True when `range` of `text` lies in prose: outside code, and no word it touches reads as code.
    static func isProse(_ text: NSString, range: NSRange) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return true }
        if codeRanges(in: text).contains(where: { NSIntersectionRange($0, range).length > 0 }) { return false }
        var start = range.location
        while start > 0, !isSpace(text.character(at: start - 1)) { start -= 1 }
        var end = NSMaxRange(range)
        while end < text.length, !isSpace(text.character(at: end)) { end += 1 }
        let words = text.substring(with: NSRange(location: start, length: end - start)).split(whereSeparator: \.isWhitespace)
        return !words.contains { isCodeLike(String($0)) }
    }

    /// A whitespace-delimited word that reads as code or a reference rather than prose.
    static func isCodeLike(_ word: String) -> Bool {
        var scalars = Substring(word).unicodeScalars
        while let first = scalars.first, leadingPunctuation.contains(first) { scalars.removeFirst() }
        while let last = scalars.last, trailingPunctuation.contains(last) { scalars.removeLast() }
        guard let first = scalars.first else { return false }
        if codeStarts.contains(first) { return true }
        var previous: Unicode.Scalar?
        for scalar in scalars {
            if codeCharacters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) { return true }
            if let previous, CharacterSet.lowercaseLetters.contains(previous), CharacterSet.uppercaseLetters.contains(scalar) { return true }
            previous = scalar
        }
        return false
    }

    /// Fenced blocks (from a ``` or ~~~ line through the closing fence of the same kind, or the
    /// end) and inline spans (a backtick through the next one on the same line).
    static func codeRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var fence: (start: Int, marker: String)?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
            let content = text.substring(with: line).trimmingCharacters(in: .whitespaces)
            let marker = ["```", "~~~"].first { content.hasPrefix($0) }
            if let open = fence {
                if marker == open.marker {
                    ranges.append(NSRange(location: open.start, length: NSMaxRange(enclosing) - open.start))
                    fence = nil
                }
                return
            }
            if let marker {
                fence = (line.location, marker)
                return
            }
            var open: Int?
            for offset in 0..<line.length where text.character(at: line.location + offset) == 0x60 {
                if let start = open {
                    ranges.append(NSRange(location: start, length: line.location + offset + 1 - start))
                    open = nil
                } else {
                    open = line.location + offset
                }
            }
        }
        if let fence { ranges.append(NSRange(location: fence.start, length: text.length - fence.start)) }
        return ranges
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
