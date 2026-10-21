import AppKit
import Testing
@testable import Soprano

@MainActor
struct ChromeComponentTests {
    @Test func statusMarksAreRingsForQuietStatesDotsForActivityAndADiamondForErrors() {
        #expect(ChromeStatus.starting.shape == .ring)
        #expect(ChromeStatus.ready.shape == .ring)
        #expect(ChromeStatus.stopped.shape == .ring)
        #expect(ChromeStatus.working.shape == .dot)
        #expect(ChromeStatus.running.shape == .dot)
        #expect(ChromeStatus.needsInput.shape == .dot)
        #expect(ChromeStatus.error.shape == .diamond)
        #expect(ChromeStatus.idle.shape == .idle)

        let colors = AppTheme.folioPaper.colors
        #expect(ChromeStatus.needsInput.headerWash(in: colors) == colors.needsInputWash)
        #expect(ChromeStatus.error.headerWash(in: colors) == colors.errorWash)
        #expect(ChromeStatus.working.headerWash(in: colors) == nil)
    }

    @Test func aKeycapSequenceIsOneCapPerStep() {
        let group = ChromeKeycapGroupView(caps: ["⌃A", "⇧P"], theme: .folioPaper)
        let legends = group.arrangedSubviews.compactMap { ($0 as? ChromeKeycapView)?.legend }
        #expect(legends == ["⌃A", "⇧P"])

        group.caps = ["esc"]
        #expect(group.arrangedSubviews.count == 1)
    }

    @Test func eyebrowsAndStatusLabelsAreUppercaseWhileOtherTextKeepsItsCase() {
        let label = NSTextField(labelWithString: "")
        label.setEyebrowText("Windows", color: .black)
        #expect(label.stringValue == "WINDOWS")
        label.setStatusText("Needs input", color: .black)
        #expect(label.stringValue == "NEEDS INPUT")
        label.setChromeText("Agent Dashboard", color: .black)
        #expect(label.stringValue == "Agent Dashboard")
    }

    @Test func theModeChipShowsItsModeInUppercase() {
        let chip = ChromeModeChip(theme: .folioInk)
        chip.set(mode: .prefix, text: "Prefix")
        #expect(chip.displayedText == "PREFIX")
        #expect(chip.mode == .prefix)
    }

    @Test func aClickTogglesOnReleaseInsideTheControl() throws {
        for make in toggleFactories {
            let receiver = ActionReceiver()
            let (toggle, window) = host(make(receiver))
            defer { window.contentView = nil }

            toggle.mouseDown(with: try mouse(.leftMouseDown, at: center(of: toggle), in: window))
            #expect(toggle.state == .off)
            #expect(receiver.count == 0)

            toggle.mouseUp(with: try mouse(.leftMouseUp, at: center(of: toggle), in: window))
            #expect(toggle.state == .on)
            #expect(receiver.count == 1)
        }
    }

    @Test func releasingOutsideTheControlCancelsTheClick() throws {
        for make in toggleFactories {
            let receiver = ActionReceiver()
            let (toggle, window) = host(make(receiver))
            defer { window.contentView = nil }

            toggle.mouseDown(with: try mouse(.leftMouseDown, at: center(of: toggle), in: window))
            let outside = NSPoint(x: toggle.frame.maxX + 40, y: toggle.frame.midY)
            toggle.mouseUp(with: try mouse(.leftMouseUp, at: outside, in: window))

            #expect(toggle.state == .off)
            #expect(receiver.count == 0)
        }
    }

    @Test func aDisabledToggleIgnoresClicksSpaceAndAccessibilityPresses() throws {
        for make in toggleFactories {
            let receiver = ActionReceiver()
            let (toggle, window) = host(make(receiver))
            defer { window.contentView = nil }
            toggle.isEnabled = false

            toggle.mouseDown(with: try mouse(.leftMouseDown, at: center(of: toggle), in: window))
            toggle.mouseUp(with: try mouse(.leftMouseUp, at: center(of: toggle), in: window))
            toggle.keyDown(with: try space(in: window))
            #expect(toggle.accessibilityPerformPress() == false)

            #expect(toggle.state == .off)
            #expect(receiver.count == 0)
        }
    }

    @Test func spaceTogglesAnEnabledToggle() throws {
        for make in toggleFactories {
            let receiver = ActionReceiver()
            let (toggle, window) = host(make(receiver))
            defer { window.contentView = nil }

            toggle.keyDown(with: try space(in: window))
            #expect(toggle.state == .on)
            #expect(receiver.count == 1)
        }
    }

    @Test func togglesTakeKeyboardFocusOnlyWhenEnabledUnderFullKeyboardAccess() {
        let fullKeyboardAccess = NSApplication.shared.isFullKeyboardAccessEnabled
        for make in toggleFactories {
            let toggle = make(ActionReceiver())
            #expect(toggle.canBecomeKeyView == fullKeyboardAccess)
            #expect(toggle.acceptsFirstResponder == fullKeyboardAccess)
            #expect(toggle.focusRingMaskBounds == toggle.bounds)

            toggle.isEnabled = false
            #expect(toggle.canBecomeKeyView == false)
            #expect(toggle.acceptsFirstResponder == false)
        }
    }

    @Test func aKeycapSequenceIsReadOnceAsAWhole() {
        let group = ChromeKeycapGroupView(caps: ["⌃A", "P"], theme: .folioInk)
        #expect(group.isAccessibilityElement())
        #expect(group.accessibilityLabel() == "⌃A then P")
        #expect(group.arrangedSubviews.allSatisfy { !$0.isAccessibilityElement() })
    }

    @Test func clickingAFieldsPaddingFocusesItsTextField() throws {
        let surface = ChromeFieldView(theme: .folioPaper)
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.frame = NSRect(x: 20, y: 20, width: 200, height: 30)
        let field = NSTextField(string: "")
        ChromeFieldView.styleEmbedded(field, colors: AppTheme.folioPaper.colors)
        field.frame = NSRect(x: 10, y: 7, width: 180, height: 16)
        surface.addSubview(field)
        let window = makeWindow()
        window.contentView?.addSubview(surface)
        defer { window.contentView = nil }

        let padding = NSPoint(x: surface.frame.minX + 4, y: surface.frame.midY)
        surface.mouseDown(with: try mouse(.leftMouseDown, at: padding, in: window))

        #expect(field.currentEditor() != nil)
    }

    @Test func serifRolesUseNewYorkAtFifteenPointsOrMore() {
        for font in [ChromeFont.title, ChromeFont.screen, ChromeFont.headline, ChromeFont.empty, ChromeFont.figure] {
            #expect(font.pointSize >= 15)
            #expect(font.fontDescriptor.symbolicTraits.contains(.italic) == (font == ChromeFont.empty))
        }
        #expect(ChromeFont.meta.pointSize == 11)
    }
}

@MainActor
private final class ActionReceiver: NSObject {
    var count = 0

    @objc func fire(_ sender: Any?) {
        count += 1
    }
}

private extension ChromeComponentTests {
    var toggleFactories: [(ActionReceiver) -> ChromeToggleControl] {
        [
            { ChromeSwitch(isOn: false, theme: .folioPaper, target: $0, action: #selector(ActionReceiver.fire(_:))) },
            { ChromeCheckbox(isChecked: false, theme: .folioInk, target: $0, action: #selector(ActionReceiver.fire(_:))) },
        ]
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        return window
    }

    func host(_ toggle: ChromeToggleControl) -> (ChromeToggleControl, NSWindow) {
        let window = makeWindow()
        toggle.translatesAutoresizingMaskIntoConstraints = true
        toggle.frame = NSRect(origin: NSPoint(x: 20, y: 20), size: toggle.intrinsicContentSize)
        window.contentView?.addSubview(toggle)
        return (toggle, window)
    }

    /// The control's center in window coordinates.
    func center(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    func mouse(_ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    func space(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))
    }
}
