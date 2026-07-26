import AppKit
import Testing
@testable import Soprano

struct KeyChordTests {
    @Test func writtenChordsParseIntoBindingFieldsAndRoundTripThroughCanonicalText() {
        let cases: [(text: String, canonical: String, chord: KeyChord)] = [
            ("cmd+p", "cmd+p", KeyChord(mode: .direct, key: "p", meta: true)),
            ("cmd+shift+p", "cmd+shift+p", KeyChord(mode: .direct, key: "p", meta: true, shift: true)),
            ("ctrl+h", "ctrl+h", KeyChord(mode: .direct, key: "h", ctrl: true)),
            ("ctrl+shift+l", "ctrl+shift+l", KeyChord(mode: .direct, key: "l", ctrl: true, shift: true)),
            ("prefix+n", "prefix+n", KeyChord(mode: .prefix, key: "n")),
            ("prefix+shift+n", "prefix+shift+n", KeyChord(mode: .prefix, key: "n", shift: true)),
            ("prefix+|", "prefix+|", KeyChord(mode: .prefix, key: "|")),
            ("prefix+-", "prefix+-", KeyChord(mode: .prefix, key: "-")),
            ("cmd+,", "cmd+,", KeyChord(mode: .direct, key: ",", meta: true)),
            ("ctrl+space", "ctrl+space", KeyChord(mode: .direct, key: " ", ctrl: true)),
            ("prefix+left", "prefix+left", KeyChord(mode: .prefix, key: "\u{F702}")),
            ("cmd+enter", "cmd+enter", KeyChord(mode: .direct, key: "\r", meta: true)),
            ("cmd+escape", "cmd+escape", KeyChord(mode: .direct, key: "\u{1B}", meta: true)),
            ("cmd+backspace", "cmd+backspace", KeyChord(mode: .direct, key: "\u{7F}", meta: true)),
            ("p", "p", KeyChord(mode: .direct, key: "p")),
        ]

        for testCase in cases {
            let parsed = KeyChord.parse(testCase.text)
            #expect(parsed == testCase.chord, "parsing \(testCase.text)")
            #expect(parsed?.canonicalString == testCase.canonical, "canonical form of \(testCase.text)")
            #expect(
                KeyChord.parse(testCase.canonical) == testCase.chord,
                "re-parsing canonical \(testCase.canonical)"
            )
        }
    }

    @Test func aliasesAndCasingAndWhitespaceAllResolveToTheSameChord() {
        let expected = KeyChord(mode: .direct, key: "p", meta: true, shift: true)

        #expect(KeyChord.parse("Command+Shift+P") == expected)
        #expect(KeyChord.parse("META + shift + p") == expected)
        #expect(KeyChord.parse("super+⇧+P") == expected)
        #expect(KeyChord.parse("⌘+shift+p") == expected)

        // An uppercase letter names the letter, it does not imply Shift.
        #expect(KeyChord.parse("cmd+P") == KeyChord(mode: .direct, key: "p", meta: true))

        #expect(KeyChord.parse("control+h") == KeyChord(mode: .direct, key: "h", ctrl: true))
        #expect(KeyChord.parse("^+h") == KeyChord(mode: .direct, key: "h", ctrl: true))
    }

    @Test func namedKeysResolveToTheCharacterTheKeyboardReports() {
        // KeybindingManager compares against
        // NSEvent.charactersIgnoringModifiers?.lowercased(), so the named keys
        // have to land on exactly those characters.
        let expectations: [(name: String, key: String)] = [
            ("space", " "),
            ("tab", "\t"),
            ("enter", "\r"),
            ("return", "\r"),
            ("escape", "\u{1B}"),
            ("esc", "\u{1B}"),
            ("backspace", "\u{7F}"),
            ("delete", "\u{7F}"),
            ("up", "\u{F700}"),
            ("down", "\u{F701}"),
            ("left", "\u{F702}"),
            ("right", "\u{F703}"),
            ("comma", ","),
            ("period", "."),
            ("dot", "."),
            ("slash", "/"),
            ("backslash", "\\"),
            ("minus", "-"),
            ("dash", "-"),
            ("equal", "="),
            ("equals", "="),
            ("plus", "+"),
            ("semicolon", ";"),
            ("quote", "'"),
            ("backtick", "`"),
            ("bracketleft", "["),
            ("bracketright", "]"),
        ]

        for expectation in expectations {
            #expect(
                KeyChord.parse("ctrl+\(expectation.name)")?.key == expectation.key,
                "named key \(expectation.name)"
            )
        }

        for literal in [",", ".", "/", "\\", "-", "=", ";", "'", "`", "[", "]", "|"] {
            #expect(KeyChord.parse("ctrl+\(literal)")?.key == literal, "literal key \(literal)")
        }
    }

    @Test func aLiteralPlusCanBeWrittenAsPlusOrAsATrailingSeparator() {
        let expected = KeyChord(mode: .direct, key: "+", meta: true)

        #expect(KeyChord.parse("cmd++") == expected)
        #expect(KeyChord.parse("cmd+plus") == expected)
        #expect(KeyChord.parse("cmd+") == expected)
        #expect(expected.canonicalString == "cmd+plus")
        #expect(KeyChord.parse(expected.canonicalString) == expected)
    }

    @Test func everyBuiltInBindingSurvivesAChordRoundTrip() {
        // Guards against a vacuously passing loop: the point is that the
        // encoding covers the whole real binding set, not a sample of it.
        #expect(DefaultKeybindings.config.bindings.count >= 50)

        for binding in DefaultKeybindings.config.bindings {
            let chord = KeyChord(binding: binding)
            #expect(
                KeyChord.parse(chord.canonicalString) == chord,
                "\(binding.id) via \(chord.canonicalString)"
            )
            #expect(chord.key == binding.key, "\(binding.id) key")
            #expect(chord.ctrl == (binding.ctrl == true), "\(binding.id) ctrl")
            #expect(chord.meta == (binding.meta == true), "\(binding.id) meta")
            #expect(chord.shift == (binding.shift == true), "\(binding.id) shift")
        }
    }

    @Test func shiftedSymbolChordsMatchTheBuiltInSplitVerticalBinding() throws {
        let splitVertical = try #require(
            DefaultKeybindings.config.bindings.first { $0.id == "split-vertical" }
        )
        let parsed = try #require(KeyChord.parse("prefix+shift+|"))

        #expect(parsed.mode == splitVertical.mode)
        #expect(parsed.key == splitVertical.key)
        #expect(parsed.shift == (splitVertical.shift == true))
        #expect(parsed.ctrl == (splitVertical.ctrl == true))
        #expect(parsed.meta == (splitVertical.meta == true))
        #expect(parsed.displayString == splitVertical.defaultKeys)
    }

    @Test func prefixChordsIgnoreCtrlAndCommandBecauseThePrefixAlreadyConsumesThem() {
        // matchesPrefixBinding only compares the key and Shift, so a prefix
        // chord that claims Ctrl or Cmd would be a lie.
        let chord = KeyChord(mode: .prefix, key: "n", ctrl: true, meta: true, shift: true)

        #expect(!chord.ctrl)
        #expect(!chord.meta)
        #expect(chord.shift)
        #expect(chord.canonicalString == "prefix+shift+n")
    }

    @Test func unparseableChordsAreRejectedInsteadOfSilentlyLosingModifiers() {
        let rejected = [
            "alt+x",
            "opt+x",
            "option+x",
            "⌥+x",
            "fn+x",
            "prefix+cmd+x",
            "prefix+ctrl+x",
            "cmd",
            "shift",
            "prefix",
            "",
            "   ",
            "cmd+a+b",
            "nonsense+x",
            "cmd+nonsense",
        ]

        for text in rejected {
            #expect(KeyChord.parse(text) == nil, "expected \"\(text)\" to be rejected")
        }
    }

    @Test func applyingAChordRewritesOnlyTheShortcutFields() throws {
        let original = try #require(
            DefaultKeybindings.config.bindings.first { $0.id == "command-palette" }
        )
        let chord = try #require(KeyChord.parse("ctrl+shift+k"))
        let applied = chord.applied(to: original)

        #expect(applied.id == original.id)
        #expect(applied.label == original.label)
        #expect(applied.description == original.description)
        #expect(applied.category == original.category)

        #expect(applied.mode == .direct)
        #expect(applied.key == "k")
        #expect(applied.ctrl == true)
        #expect(applied.shift == true)
        #expect(applied.meta == nil)
        #expect(applied.defaultKeys == "Ctrl+Shift+K")

        // The rewritten binding is itself round-trippable.
        #expect(KeyChord(binding: applied) == chord)
    }

    @Test func applyingAChordClearsModifiersTheNewChordDoesNotUse() throws {
        let original = try #require(
            DefaultKeybindings.config.bindings.first { $0.id == "open-project" }
        )
        let applied = try #require(KeyChord.parse("prefix+o")).applied(to: original)

        #expect(applied.mode == .prefix)
        #expect(applied.key == "o")
        #expect(applied.ctrl == nil)
        #expect(applied.meta == nil)
        #expect(applied.shift == nil)
        #expect(applied.defaultKeys == "Prefix → O")
    }

    @Test func displayStringsFollowTheConventionsOfTheBuiltInTable() {
        let expectations: [(text: String, display: String)] = [
            ("cmd+p", "⌘P"),
            ("cmd+shift+s", "⇧⌘S"),
            ("cmd+1", "⌘1"),
            ("cmd+,", "⌘,"),
            ("cmd+-", "⌘-"),
            ("ctrl+cmd+shift+p", "⌃⇧⌘P"),
            ("ctrl+h", "Ctrl+H"),
            ("ctrl+shift+l", "Ctrl+Shift+L"),
            ("ctrl+1", "Ctrl+1"),
            ("p", "P"),
            ("prefix+n", "Prefix → N"),
            ("prefix+shift+n", "Prefix → Shift+N"),
            ("prefix+|", "Prefix → |"),
            ("prefix+shift+|", "Prefix → |"),
            ("prefix+-", "Prefix → -"),
            ("prefix+[", "Prefix → ["),
            ("ctrl+space", "Ctrl+Space"),
            ("ctrl+tab", "Ctrl+Tab"),
            ("cmd+enter", "⌘Enter"),
            ("cmd+escape", "⌘Esc"),
            ("cmd+backspace", "⌘Backspace"),
            ("prefix+left", "Prefix → ←"),
            ("prefix+up", "Prefix → ↑"),
            ("ctrl+down", "Ctrl+↓"),
            ("cmd+right", "⌘→"),
        ]

        for expectation in expectations {
            #expect(
                KeyChord.parse(expectation.text)?.displayString == expectation.display,
                "display of \(expectation.text)"
            )
        }
    }

    @Test func builtInBindingsRenderTheSameDisplayStringTheyShipWith() {
        // The resize bindings ship a display string that omits the Shift they
        // require, and zoom-in advertises two chords in one string; every
        // other built-in must render byte-identically.
        let knownDeviations: Set<String> = [
            "resize-left", "resize-down", "resize-up", "resize-right", "zoom-in",
        ]

        for binding in DefaultKeybindings.config.bindings where !knownDeviations.contains(binding.id) {
            #expect(
                KeyChord(binding: binding).displayString == binding.defaultKeys,
                "\(binding.id) display"
            )
        }

        let byId = Dictionary(
            uniqueKeysWithValues: DefaultKeybindings.config.bindings.map { ($0.id, $0) }
        )
        #expect(byId["resize-left"].map { KeyChord(binding: $0).displayString } == "Prefix → Shift+H")
        #expect(byId["zoom-in"].map { KeyChord(binding: $0).displayString } == "⌘=")
    }
}
