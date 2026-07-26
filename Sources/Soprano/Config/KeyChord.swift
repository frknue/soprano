import Foundation

/// A keyboard chord written the way a human types it — "cmd+shift+p",
/// "ctrl+h", "prefix+|" — and its translation to `KeyBinding`'s field
/// representation.
///
/// Settings files (`~/.config/soprano/settings.json`) express shortcuts as
/// text, but `KeybindingManager` matches live events against
/// `mode`/`key`/`ctrl`/`meta`/`shift`. `KeyChord` is the single place that
/// converts between the two, so a rebound shortcut behaves — and renders —
/// exactly like a built-in one.
///
/// `key` always holds the string `NSEvent.charactersIgnoringModifiers?
/// .lowercased()` reports for that physical key, because that is what the
/// manager compares against. That is why a shifted symbol such as `|` is
/// stored as `"|"` with `shift == true` (matching the built-in
/// "split-vertical" binding) rather than as backslash-plus-shift.
struct KeyChord: Equatable, Hashable {
    var mode: KeyBindingMode
    /// Lowercased single character (or the character a named key produces).
    var key: String
    var ctrl: Bool
    var meta: Bool
    var shift: Bool

    /// Two normalizations happen here, both so that chords which behave
    /// identically at the keyboard compare equal:
    ///
    /// - Ctrl and Cmd are dropped for prefix chords: the prefix itself is
    ///   Ctrl+<prefixKey>, and `KeybindingManager.matchesPrefixBinding` only
    ///   compares the key and Shift.
    /// - Shift is *inferred* for characters that cannot be typed without it.
    ///   `charactersIgnoringModifiers` applies Shift, so pressing that key
    ///   reports `|` **and** a Shift flag; a chord written `"prefix+|"` without
    ///   Shift would therefore match nothing and fail silently. Inferring it
    ///   makes the obvious spelling work, and matches how the built-in
    ///   "split-vertical" binding is encoded.
    init(mode: KeyBindingMode, key: String, ctrl: Bool = false, meta: Bool = false, shift: Bool = false) {
        let normalizedKey = key.lowercased()
        self.mode = mode
        self.key = normalizedKey
        self.ctrl = mode == .prefix ? false : ctrl
        self.meta = mode == .prefix ? false : meta
        self.shift = shift || Self.shiftedSymbols.contains(normalizedKey)
    }

    init(binding: KeyBinding) {
        self.init(
            mode: binding.mode,
            key: binding.key,
            ctrl: binding.ctrl == true,
            meta: binding.meta == true,
            shift: binding.shift == true
        )
    }

    // MARK: - Parsing

    /// Parse a user-written chord. Returns nil when the text names no key or
    /// contains an unknown token.
    ///
    /// Tokens are separated by `+`, compared case-insensitively, and may be
    /// padded with whitespace. A literal `+` is written either as `plus` or by
    /// trailing the separator ("cmd++", and the lenient "cmd+" form).
    ///
    /// Unknown tokens are rejected rather than ignored — `KeyBinding` has no
    /// Option flag, so silently dropping "alt" would install a shortcut that
    /// fires on the unmodified key.
    static func parse(_ text: String) -> KeyChord? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Splitting on "+" turns a literal "+" key into empty components
        // ("cmd++" → ["cmd", "", ""]). Collapse any number of them into one
        // explicit key token so both spellings land on the same chord.
        var tokens: [String] = []
        var sawEmptyComponent = false
        for component in trimmed.components(separatedBy: "+") {
            let token = component.trimmingCharacters(in: .whitespaces).lowercased()
            if token.isEmpty {
                sawEmptyComponent = true
            } else {
                tokens.append(token)
            }
        }
        if sawEmptyComponent {
            tokens.append("+")
        }

        var mode = KeyBindingMode.direct
        var ctrl = false
        var meta = false
        var shift = false
        var key: String?

        for token in tokens {
            if token == "prefix" {
                mode = .prefix
            } else if metaAliases.contains(token) {
                meta = true
            } else if ctrlAliases.contains(token) {
                ctrl = true
            } else if shiftAliases.contains(token) {
                shift = true
            } else if unsupportedModifierAliases.contains(token) {
                return nil
            } else {
                guard let resolved = resolveKey(token), key == nil else { return nil }
                key = resolved
            }
        }

        guard let key else { return nil }
        // The prefix chord already consumes Ctrl, and prefix matching ignores
        // Ctrl/Cmd entirely — accepting them would silently bind something else.
        guard !(mode == .prefix && (ctrl || meta)) else { return nil }

        return KeyChord(mode: mode, key: key, ctrl: ctrl, meta: meta, shift: shift)
    }

    /// An uppercase letter means the letter, not implicit Shift (VS Code
    /// semantics): "cmd+P" is ⌘P, not ⇧⌘P.
    private static func resolveKey(_ token: String) -> String? {
        if let named = namedKeys[token] { return named }
        guard token.count == 1 else { return nil }
        return token
    }

    // MARK: - Rendering

    /// Round-trippable canonical form, e.g. "cmd+shift+p", "prefix+shift+n".
    ///
    /// Modifiers are written in a fixed order — prefix, ctrl, cmd, shift —
    /// followed by the key. Keys that cannot be written literally (invisible
    /// keys, and `+` itself) use their name: "cmd+plus", "ctrl+space".
    var canonicalString: String {
        var parts: [String] = []
        if mode == .prefix { parts.append("prefix") }
        if ctrl { parts.append("ctrl") }
        if meta { parts.append("cmd") }
        // Shift is left implicit on keys that require it to type, matching the
        // inference in `init`: "prefix+|" round-trips, and reads the way the
        // user wrote it.
        if shift, !Self.shiftedSymbols.contains(key) { parts.append("shift") }
        parts.append(Self.canonicalKeyNames[key] ?? key)
        return parts.joined(separator: "+")
    }

    /// Display form matching the app's existing convention, e.g. "⇧⌘P",
    /// "Ctrl+Shift+L", "Prefix → Shift+N".
    ///
    /// The rules, derived from the built-in `defaultKeys` strings so that an
    /// overridden binding renders like a stock one:
    /// - Cmd chords use symbols in the order ⌃⇧⌘ followed by the uppercased
    ///   key: "⌘P", "⇧⌘S", "⌘1", "⌘,".
    /// - Other direct chords spell their modifiers out: "Ctrl+H",
    ///   "Ctrl+Shift+L", and a bare key renders as just "P".
    /// - Prefix chords read "Prefix → N", "Prefix → Shift+N", "Prefix → |".
    /// - Shift is omitted whenever the key is a symbol that already requires
    ///   Shift to type (`|`, `?`, `:` …), which is how the built-in
    ///   "split-vertical" binding renders "Prefix → |".
    /// - Invisible keys are named: Space, Tab, Enter, Esc, Backspace, and the
    ///   arrows as ←→↑↓.
    ///
    /// (The built-in resize bindings render shifted letters without "Shift+",
    /// e.g. "Prefix → H"; that inconsistency is not reproduced here — a
    /// shifted letter always shows "Shift+" so the string names the keys the
    /// user must actually press.)
    var displayString: String {
        let renderedKey = Self.displayKeyNames[key] ?? key.uppercased()
        let showsShift = shift && !Self.shiftedSymbols.contains(key)

        switch mode {
        case .prefix:
            return "Prefix → " + (showsShift ? "Shift+" : "") + renderedKey
        case .direct:
            guard !meta else {
                var symbols = ""
                if ctrl { symbols += "⌃" }
                if showsShift { symbols += "⇧" }
                symbols += "⌘"
                return symbols + renderedKey
            }
            var parts: [String] = []
            if ctrl { parts.append("Ctrl") }
            if showsShift { parts.append("Shift") }
            parts.append(renderedKey)
            return parts.joined(separator: "+")
        }
    }

    /// A copy of `binding` with this chord's mode/key/modifiers applied and
    /// `defaultKeys` set to `displayString`. Unset modifiers become nil, the
    /// way the built-in table encodes absence (`KeybindingManager` compares
    /// with `== true`, so nil and false behave identically).
    func applied(to binding: KeyBinding) -> KeyBinding {
        KeyBinding(
            id: binding.id,
            label: binding.label,
            description: binding.description,
            category: binding.category,
            defaultKeys: displayString,
            mode: mode,
            key: key,
            ctrl: ctrl ? true : nil,
            meta: meta ? true : nil,
            shift: shift ? true : nil
        )
    }

    // MARK: - Tokens

    private static let metaAliases: Set<String> = ["cmd", "command", "meta", "super", "⌘"]
    private static let ctrlAliases: Set<String> = ["ctrl", "control", "^"]
    private static let shiftAliases: Set<String> = ["shift", "⇧"]

    /// Named so they are rejected loudly: `KeyBinding` cannot express Option,
    /// and a chord that quietly lost a modifier would fire unexpectedly.
    private static let unsupportedModifierAliases: Set<String> = [
        "alt", "opt", "option", "⌥", "fn", "function", "hyper",
    ]

    /// Named keys → the character `NSEvent.charactersIgnoringModifiers`
    /// reports for them, since that is the value `KeybindingManager` compares
    /// bindings against.
    private static let namedKeys: [String: String] = [
        "space": " ",
        "tab": "\t",
        "enter": "\r",
        "return": "\r",
        "escape": "\u{1B}",
        "esc": "\u{1B}",
        "backspace": "\u{7F}",
        "delete": "\u{7F}",
        "up": "\u{F700}",       // NSUpArrowFunctionKey
        "down": "\u{F701}",     // NSDownArrowFunctionKey
        "left": "\u{F702}",     // NSLeftArrowFunctionKey
        "right": "\u{F703}",    // NSRightArrowFunctionKey
        "comma": ",",
        "period": ".",
        "dot": ".",
        "slash": "/",
        "backslash": "\\",
        "minus": "-",
        "dash": "-",
        "equal": "=",
        "equals": "=",
        "plus": "+",
        "semicolon": ";",
        "quote": "'",
        "backtick": "`",
        "bracketleft": "[",
        "bracketright": "]",
    ]

    /// Keys that cannot survive a literal round trip — they are invisible, or
    /// they collide with the `+` separator.
    private static let canonicalKeyNames: [String: String] = [
        " ": "space",
        "\t": "tab",
        "\r": "enter",
        "\u{1B}": "escape",
        "\u{7F}": "backspace",
        "\u{F700}": "up",
        "\u{F701}": "down",
        "\u{F702}": "left",
        "\u{F703}": "right",
        "+": "plus",
    ]

    private static let displayKeyNames: [String: String] = [
        " ": "Space",
        "\t": "Tab",
        "\r": "Enter",
        "\u{1B}": "Esc",
        "\u{7F}": "Backspace",
        "\u{F700}": "↑",
        "\u{F701}": "↓",
        "\u{F702}": "←",
        "\u{F703}": "→",
    ]

    /// US-layout characters that already require Shift to type, so spelling
    /// "Shift+" alongside them would double-count the modifier.
    private static let shiftedSymbols: Set<String> = [
        "~", "!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "_", "+",
        "{", "}", "|", ":", "\"", "<", ">", "?",
    ]
}
