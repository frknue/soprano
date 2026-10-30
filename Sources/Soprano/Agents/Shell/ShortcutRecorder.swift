import AppKit

/// Turns key presses into one chord for the settings screen's Record button.
///
/// ⌃ + the prefix key starts a prefix chord and waits for its key (⌃A then P
/// records `prefix+p`); Esc cancels; ⌥ chords, ⌃A ⌃A and keys `KeyChord`
/// cannot write back to settings.json are refused.
struct ShortcutRecorder: Equatable {
    enum Outcome: Equatable {
        /// The prefix was pressed; the next key completes a prefix chord.
        case awaitingPrefixKey
        case recorded(KeyChord)
        case cancelled
        /// The press can't be a binding; recording continues.
        case rejected
    }

    let prefixKey: String
    private(set) var isAwaitingPrefixKey = false

    init(prefixKey: String) {
        self.prefixKey = prefixKey
    }

    mutating func feed(_ stroke: KeyStroke) -> Outcome {
        if stroke.option { return .rejected }
        let isBareEscape = stroke.key == "\u{1B}" && !stroke.ctrl && !stroke.meta && !stroke.shift
        if isBareEscape { return .cancelled }
        let isPrefix = stroke.ctrl && !stroke.meta && !stroke.shift && stroke.key == prefixKey

        if isAwaitingPrefixKey {
            // ⌃A ⌃A sends a literal ⌃A in the router; it can't be a binding.
            if isPrefix { return .rejected }
            return Self.writable(KeyChord(mode: .prefix, key: stroke.key, shift: stroke.shift))
        }
        if isPrefix {
            isAwaitingPrefixKey = true
            return .awaitingPrefixKey
        }
        return Self.writable(KeyChord(mode: .direct, key: stroke.key, ctrl: stroke.ctrl, meta: stroke.meta, shift: stroke.shift))
    }

    /// Only chords that survive settings.json's text form are recorded.
    private static func writable(_ chord: KeyChord) -> Outcome {
        KeyChord.parse(chord.canonicalString) == chord ? .recorded(chord) : .rejected
    }
}
