import AppKit
import Testing
@testable import SopranoAgents

@MainActor
struct KeyboardRouterTests {
    private final class Log {
        var ran: [String] = []
    }

    private func command(
        _ id: String,
        scopes: Set<FocusRegion> = [],
        keys: [String],
        enabled: Bool = true,
        log: Log
    ) -> AppCommand {
        AppCommand(
            id: id, title: id, category: .app, scopes: scopes, defaultKeys: keys,
            isEnabled: { _ in enabled },
            perform: { _ in log.ran.append(id) }
        )
    }

    private func makeRouter(_ commands: [AppCommand], prefixTimeoutMs: Int = 1500) -> KeyboardRouter {
        let registry = CommandRegistry()
        registry.register(commands)
        let keymap = Keymap.resolve(
            commands: registry.commands,
            settings: KeybindingSettings(prefixKey: "a", prefixTimeoutMs: prefixTimeoutMs, overrides: [:])
        )
        return KeyboardRouter(registry: registry, keymap: { keymap }, context: { nil })
    }

    private func context(_ focus: FocusRegion?, textInput: Bool = false) -> CommandContext {
        CommandContext(window: nil, workspace: nil, focus: focus, isTextInput: textInput)
    }

    @Test func aRegionScopedBindingBeatsAGlobalOneOnTheSameChord() {
        let log = Log()
        let router = makeRouter([
            command("global.j", keys: ["j"], log: log),
            command("timeline.next", scopes: [.timeline], keys: ["j"], log: log),
        ])

        #expect(router.handle(KeyStroke(key: "j"), in: context(.timeline)) == .handled)
        #expect(router.handle(KeyStroke(key: "j"), in: context(.sidebar)) == .handled)

        #expect(log.ran == ["timeline.next", "global.j"])
    }

    @Test func aScopedBindingNeverFiresOutsideItsRegions() {
        let log = Log()
        let router = makeRouter([command("timeline.next", scopes: [.timeline], keys: ["j"], log: log)])

        #expect(router.handle(KeyStroke(key: "j"), in: context(.composer)) == .passThrough)
        #expect(router.handle(KeyStroke(key: "j"), in: context(nil)) == .passThrough)
        #expect(log.ran.isEmpty)
    }

    @Test func chordsWithoutCommandOrControlNeverFireWhileTypingText() {
        let log = Log()
        let router = makeRouter([
            command("chat.new", keys: ["cmd+b", "b"], log: log),
            command("thread.settle", keys: ["prefix+s"], log: log),
        ])

        #expect(router.handle(KeyStroke(key: "b"), in: context(.composer, textInput: true)) == .passThrough)
        #expect(router.handle(KeyStroke(key: "b", meta: true), in: context(.composer, textInput: true)) == .handled)
        // A prefix chord starts with ⌃, so it still works in a text field.
        #expect(router.handle(KeyStroke(key: "a", ctrl: true), in: context(.composer, textInput: true)) == .handled)
        #expect(router.handle(KeyStroke(key: "s"), in: context(.composer, textInput: true)) == .handled)

        #expect(log.ran == ["chat.new", "thread.settle"])
    }

    @Test func eventsWithOptionPassThroughUntouched() {
        let log = Log()
        let router = makeRouter([command("timeline.search", keys: ["cmd+l", "l"], log: log)])

        #expect(router.handle(KeyStroke(key: "l", option: true), in: context(.timeline)) == .passThrough)
        #expect(router.handle(KeyStroke(key: "l", meta: true, option: true), in: context(.timeline)) == .passThrough)
        #expect(log.ran.isEmpty)
    }

    @Test func symbolKeysMatchIgnoringShiftForGermanLayouts() {
        let log = Log()
        let router = makeRouter([
            command("help.shortcuts", keys: ["cmd+/", "?"], log: log),
            command("timeline.search", scopes: [.timeline], keys: ["/"], log: log),
        ])

        // German "?" is ⇧ß; ⌘/ is ⌘⇧7.
        #expect(router.handle(KeyStroke(key: "?", shift: true), in: context(.timeline)) == .handled)
        #expect(router.handle(KeyStroke(key: "/", meta: true, shift: true), in: context(.timeline)) == .handled)
        // US "?" carries no extra modifier; "/" on German is ⇧7.
        #expect(router.handle(KeyStroke(key: "?"), in: context(.timeline)) == .handled)
        #expect(router.handle(KeyStroke(key: "/", shift: true), in: context(.timeline)) == .handled)

        #expect(log.ran == ["help.shortcuts", "help.shortcuts", "help.shortcuts", "timeline.search"])
    }

    @Test func lettersCompareShiftExactly() {
        let log = Log()
        let router = makeRouter([
            command("timeline.next", scopes: [.timeline], keys: ["j"], log: log),
            command("timeline.nextTurn", scopes: [.timeline], keys: ["shift+j"], log: log),
        ])

        _ = router.handle(KeyStroke(key: "j", shift: true), in: context(.timeline))
        _ = router.handle(KeyStroke(key: "j"), in: context(.timeline))

        #expect(log.ran == ["timeline.nextTurn", "timeline.next"])
    }

    @Test func thePrefixChordWaitsForTheNextKeyThenRunsThePrefixBinding() {
        let log = Log()
        let router = makeRouter([
            command("thread.pin", keys: ["prefix+p"], log: log),
            command("thread.pinAll", keys: ["prefix+shift+p"], log: log),
            command("plain.p", keys: ["p"], log: log),
        ])
        var states: [KeyboardRouter.State] = []
        router.onStateChange = { states.append($0) }

        #expect(router.handle(KeyStroke(key: "a", ctrl: true), in: context(.timeline)) == .handled)
        #expect(router.state == .prefix)
        #expect(router.handle(KeyStroke(key: "p", shift: true), in: context(.timeline)) == .handled)
        #expect(router.state == .normal)
        // Unbound prefix keys are swallowed and end prefix mode.
        _ = router.handle(KeyStroke(key: "a", ctrl: true), in: context(.timeline))
        #expect(router.handle(KeyStroke(key: "z"), in: context(.timeline)) == .handled)

        #expect(log.ran == ["thread.pinAll"])
        #expect(states == [.prefix, .normal, .prefix, .normal])
    }

    @Test func pressingThePrefixTwiceSendsALiteralControlA() {
        let log = Log()
        let router = makeRouter([command("thread.pin", keys: ["prefix+p"], log: log)])

        #expect(router.handle(KeyStroke(key: "a", ctrl: true), in: context(.composer, textInput: true)) == .handled)
        #expect(router.handle(KeyStroke(key: "a", ctrl: true), in: context(.composer, textInput: true)) == .passThrough)
        #expect(router.state == .normal)
        #expect(log.ran.isEmpty)
    }

    @Test func prefixModeEndsAfterTheTimeout() async throws {
        let log = Log()
        let router = makeRouter([command("thread.pin", keys: ["prefix+p"], log: log)], prefixTimeoutMs: 60)

        _ = router.handle(KeyStroke(key: "a", ctrl: true), in: context(.timeline))
        #expect(router.state == .prefix)
        for _ in 0..<100 where router.state == .prefix {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(router.state == .normal)
        #expect(router.handle(KeyStroke(key: "p"), in: context(.timeline)) == .passThrough)
        #expect(log.ran.isEmpty)
    }

    @Test func disabledCommandsLetTheEventPassOrFallThroughToTheGlobalBinding() {
        let log = Log()
        let disabledOnly = makeRouter([command("thread.copy", scopes: [.timeline], keys: ["c"], enabled: false, log: log)])
        #expect(disabledOnly.handle(KeyStroke(key: "c"), in: context(.timeline)) == .passThrough)

        let layered = makeRouter([
            command("diff.close", scopes: [.rightPanel], keys: ["escape"], enabled: false, log: log),
            command("palette.close", keys: ["escape"], log: log),
        ])
        #expect(layered.handle(KeyStroke(key: "\u{1B}"), in: context(.rightPanel)) == .handled)
        #expect(log.ran == ["palette.close"])
    }

    @Test func whileCapturingEveryKeyGoesToTheCaptureAndNoCommandRuns() throws {
        let log = Log()
        let registry = CommandRegistry()
        registry.register([command("terminal.close", keys: ["cmd+w"], log: log)])
        let keymap = Keymap.resolve(commands: registry.commands, settings: KeybindingSettings())
        let router = KeyboardRouter(registry: registry, keymap: { keymap }, context: { self.context(.settings) })
        func event() throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
                context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13
            ))
        }
        var captured: [KeyStroke] = []

        router.capture = { captured.append($0) }
        #expect(router.dispatch(try event()) == nil)
        router.capture = nil
        #expect(router.dispatch(try event()) == nil)

        #expect(captured == [KeyStroke(key: "w", meta: true)])
        #expect(log.ran == ["terminal.close"])
    }

    @Test func keyStrokesNormalizeReturnNumpadEnterAndModifiers() throws {
        func event(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ))
        }

        let enter = try #require(KeyStroke(event: try event("\u{3}", keyCode: 76)))
        #expect(enter.key == "\r")
        let commandReturn = try #require(KeyStroke(event: try event("\r", keyCode: 36, flags: [.command, .shift])))
        #expect(commandReturn == KeyStroke(key: "\r", meta: true, shift: true))
        let shiftedLetter = try #require(KeyStroke(event: try event("J", keyCode: 38, flags: [.shift])))
        #expect(shiftedLetter == KeyStroke(key: "j", shift: true))
        #expect(shiftedLetter.matches(try #require(KeyChord.parse("shift+j")), mode: .direct))
        let option = try #require(KeyStroke(event: try event("@", keyCode: 37, flags: [.option])))
        #expect(option.option)
    }
}
