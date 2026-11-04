import AppKit

/// One key press as the router sees it: the key `NSEvent.charactersIgnoringModifiers`
/// reports (lowercased; Return, numpad Enter and Tab normalized) plus modifiers.
struct KeyStroke: Equatable, Sendable {
    var key: String
    var ctrl = false
    var meta = false
    var shift = false
    var option = false

    init(key: String, ctrl: Bool = false, meta: Bool = false, shift: Bool = false, option: Bool = false) {
        self.key = key.lowercased()
        self.ctrl = ctrl
        self.meta = meta
        self.shift = shift
        self.option = option
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key: String
        switch event.keyCode {
        case 36, 76: key = "\r" // Return, numpad Enter
        case 48: key = "\t"
        case 53: key = "\u{1B}"
        case 51: key = "\u{7F}"
        default:
            guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
            key = characters
        }
        self.init(
            key: key,
            ctrl: flags.contains(.control),
            meta: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option)
        )
    }

    /// Symbol keys match ignoring Shift, so `?` (⇧ß) and ⌘/ (⌘⇧7) work on
    /// German layouts. Letters, digits and named keys compare Shift exactly.
    static let shiftInsensitiveKeys: Set<String> = ["/", "?", ".", ",", "-", "="]

    func matches(_ chord: KeyChord, mode: KeyBindingMode) -> Bool {
        guard chord.mode == mode, chord.key == key else { return false }
        if mode == .direct, chord.ctrl != ctrl || chord.meta != meta { return false }
        if Self.shiftInsensitiveKeys.contains(key) { return true }
        return chord.shift == shift
    }
}

extension KeyChord {
    /// Identity used for conflict checks: Shift is ignored on symbol keys,
    /// exactly like the router's matching.
    var conflictKey: String {
        let shiftPart = KeyStroke.shiftInsensitiveKeys.contains(key) ? "*" : (shift ? "s" : "-")
        return "\(mode.rawValue)|\(ctrl ? "c" : "-")\(meta ? "m" : "-")\(shiftPart)|\(key)"
    }

    /// The menu key equivalent for direct ⌘ chords, nil otherwise.
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard mode == .direct, meta else { return nil }
        var modifiers: NSEvent.ModifierFlags = [.command]
        if ctrl { modifiers.insert(.control) }
        if shift, !KeyStroke.shiftInsensitiveKeys.contains(key) { modifiers.insert(.shift) }
        let equivalent: String = switch key {
        case "\r": "\r"
        case "\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}": key
        default: key
        }
        return (equivalent, modifiers)
    }

    /// Keycaps under Folio's K1 rule, one legend per cap: a chord is one cap
    /// with its modifiers in macOS order (⌃⇧⌘) before the key; a prefix chord
    /// is two caps, the prefix (⌃ + `prefixKey`) then the key; letters are
    /// uppercase, named keys lowercase. `cmd+shift+o` → `["⇧⌘O"]`,
    /// `prefix+shift+p` → `["⌃A", "⇧P"]`, `j` → `["J"]`, `escape` → `["esc"]`.
    func keycaps(prefixKey: String) -> [String] {
        let names: [String: String] = [
            " ": "space", "\t": "⇥", "\r": "↵", "\u{1B}": "esc", "\u{7F}": "⌫",
            "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
        ]
        let rendered = names[key] ?? key.uppercased()
        let showsShift = shift && !KeyStroke.shiftInsensitiveKeys.contains(key) && !"~!@#$%^&*()_+{}|:\"<>?".contains(key)
        var cap = ""
        if ctrl { cap += "⌃" }
        if showsShift { cap += "⇧" }
        if meta { cap += "⌘" }
        cap += rendered
        if mode == .prefix {
            return ["⌃" + prefixKey.uppercased(), cap]
        }
        return [cap]
    }
}

/// Key bindings after settings.json overrides, resolved against the command
/// registry. Every command's chords, the prefix key and timeout, and the
/// problems found while resolving.
@MainActor
struct Keymap {
    var prefixKey: String
    var prefixTimeoutMs: Int
    private(set) var chordsByCommand: [String: [KeyChord]]
    private(set) var issues: [ConfigIssue]
    /// Commands whose bindings settings.json changes.
    private(set) var customizedIDs: Set<String>
    /// Commands with a chord that never fires: shadowed by another command in
    /// an overlapping scope, or equal to the prefix chord.
    private(set) var conflictingIDs: Set<String> = []

    init(prefixKey: String = "a", prefixTimeoutMs: Int = 1500, chordsByCommand: [String: [KeyChord]] = [:]) {
        self.prefixKey = prefixKey
        self.prefixTimeoutMs = prefixTimeoutMs
        self.chordsByCommand = chordsByCommand
        self.issues = []
        self.customizedIDs = []
    }

    func chords(for commandID: String) -> [KeyChord] {
        chordsByCommand[commandID] ?? []
    }

    /// The prefix chord itself (⌃ + prefixKey).
    var prefixChord: KeyChord {
        KeyChord(mode: .direct, key: prefixKey, ctrl: true)
    }

    static func resolve(commands: [AppCommand], settings: KeybindingSettings) -> Keymap {
        var keymap = Keymap(prefixKey: settings.prefixKey, prefixTimeoutMs: settings.prefixTimeoutMs)
        var issues: [ConfigIssue] = []
        var chords: [String: [KeyChord]] = [:]
        var commandIDs: Set<String> = []

        for command in commands {
            commandIDs.insert(command.id)
            chords[command.id] = command.defaultKeys.compactMap { text in
                guard let chord = KeyChord.parse(text) else {
                    issues.append(ConfigIssue(
                        severity: .warning,
                        message: "Built-in binding \"\(text)\" of \"\(command.id)\" is not a valid chord."
                    ))
                    return nil
                }
                return chord
            }
        }

        for id in settings.overrides.keys.sorted() {
            guard let override = settings.overrides[id] else { continue }
            guard commandIDs.contains(id) else {
                issues.append(ConfigIssue(severity: .warning, message: "keybindings.bindings: unknown command \"\(id)\"."))
                continue
            }
            switch override {
            case .disabled:
                chords[id] = []
                keymap.customizedIDs.insert(id)
            case let .chords(texts):
                var parsed: [KeyChord] = []
                var valid = true
                for text in texts {
                    if let chord = KeyChord.parse(text) {
                        if !parsed.contains(chord) { parsed.append(chord) }
                    } else {
                        valid = false
                        issues.append(ConfigIssue(
                            severity: .warning,
                            message: "keybindings.bindings.\(id): \"\(text)\" is not a valid chord."
                        ))
                    }
                }
                // A partly invalid list still applies its valid chords; a list
                // with nothing valid keeps the defaults rather than unbinding.
                if !parsed.isEmpty || (valid && texts.isEmpty) {
                    chords[id] = parsed
                    keymap.customizedIDs.insert(id)
                }
            }
        }

        keymap.chordsByCommand = chords
        let found = conflicts(commands: commands, chords: chords, prefixKey: settings.prefixKey)
        issues.append(contentsOf: found.issues)
        keymap.conflictingIDs = found.ids
        keymap.issues = issues
        return keymap
    }

    /// Two commands on the same chord with overlapping scopes means one never
    /// fires. A region-scoped binding over a global one is intended (region
    /// beats global) and is not a conflict.
    private static func conflicts(
        commands: [AppCommand],
        chords: [String: [KeyChord]],
        prefixKey: String
    ) -> (issues: [ConfigIssue], ids: Set<String>) {
        var issues: [ConfigIssue] = []
        var ids: Set<String> = []
        var seen: [String: [(id: String, scopes: Set<FocusRegion>)]] = [:]
        let prefixChord = KeyChord(mode: .direct, key: prefixKey, ctrl: true)

        for command in commands {
            for chord in chords[command.id] ?? [] {
                if chord.conflictKey == prefixChord.conflictKey {
                    ids.insert(command.id)
                    issues.append(ConfigIssue(
                        severity: .warning,
                        message: "\"\(command.id)\" is bound to \(chord.displayString), which is the prefix key; it will never fire."
                    ))
                    continue
                }
                let key = chord.conflictKey
                for owner in seen[key] ?? [] where scopesOverlap(owner.scopes, command.scopes) {
                    let place = command.scopes.isEmpty ? "globally" : "in " + command.scopes.intersection(owner.scopes.isEmpty ? command.scopes : owner.scopes).map(\.rawValue).sorted().joined(separator: ", ")
                    ids.formUnion([command.id, owner.id])
                    issues.append(ConfigIssue(
                        severity: .warning,
                        message: "\"\(command.id)\" and \"\(owner.id)\" are both bound to \(chord.displayString) \(place); only \"\(owner.id)\" will fire."
                    ))
                }
                seen[key, default: []].append((command.id, command.scopes))
            }
        }
        return (issues, ids)
    }

    private static func scopesOverlap(_ lhs: Set<FocusRegion>, _ rhs: Set<FocusRegion>) -> Bool {
        if lhs.isEmpty && rhs.isEmpty { return true }
        if lhs.isEmpty || rhs.isEmpty { return false }
        return !lhs.isDisjoint(with: rhs)
    }
}
