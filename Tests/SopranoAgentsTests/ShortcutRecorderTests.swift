import AppKit
import Testing
@testable import Soprano

struct ShortcutRecorderTests {
    @Test func aDirectChordIsRecordedWithItsModifiers() {
        var recorder = ShortcutRecorder(prefixKey: "a")

        #expect(recorder.feed(KeyStroke(key: "l", meta: true, shift: true)) == .recorded(KeyChord(mode: .direct, key: "l", meta: true, shift: true)))
        #expect(KeyChord.parse("cmd+shift+l") == KeyChord(mode: .direct, key: "l", meta: true, shift: true))
    }

    @Test func thePrefixWaitsForItsKeyAndRecordsAPrefixChord() {
        var recorder = ShortcutRecorder(prefixKey: "b")

        #expect(recorder.feed(KeyStroke(key: "b", ctrl: true)) == .awaitingPrefixKey)
        #expect(recorder.isAwaitingPrefixKey)
        let outcome = recorder.feed(KeyStroke(key: "p", shift: true))

        #expect(outcome == .recorded(KeyChord(mode: .prefix, key: "p", shift: true)))
        if case let .recorded(chord) = outcome {
            #expect(chord.canonicalString == "prefix+shift+p")
        }
    }

    @Test func ctrlWithAnotherLetterIsADirectChordNotThePrefix() {
        var recorder = ShortcutRecorder(prefixKey: "a")

        #expect(recorder.feed(KeyStroke(key: "h", ctrl: true)) == .recorded(KeyChord(mode: .direct, key: "h", ctrl: true)))
    }

    @Test func escapeCancelsEvenAfterThePrefix() {
        var direct = ShortcutRecorder(prefixKey: "a")
        #expect(direct.feed(KeyStroke(key: "\u{1B}")) == .cancelled)

        var afterPrefix = ShortcutRecorder(prefixKey: "a")
        _ = afterPrefix.feed(KeyStroke(key: "a", ctrl: true))
        #expect(afterPrefix.feed(KeyStroke(key: "\u{1B}")) == .cancelled)
    }

    @Test func optionChordsAndADoublePrefixAreRefusedAndRecordingContinues() {
        var recorder = ShortcutRecorder(prefixKey: "a")

        #expect(recorder.feed(KeyStroke(key: "l", meta: true, option: true)) == .rejected)
        #expect(recorder.feed(KeyStroke(key: "a", ctrl: true)) == .awaitingPrefixKey)
        #expect(recorder.feed(KeyStroke(key: "a", ctrl: true)) == .rejected)
        #expect(recorder.feed(KeyStroke(key: "x")) == .recorded(KeyChord(mode: .prefix, key: "x")))
    }
}
