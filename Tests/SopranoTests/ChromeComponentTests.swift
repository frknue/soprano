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

    @Test func clickingASwitchFlipsItAndSendsItsAction() {
        let receiver = ActionReceiver()
        let toggle = ChromeSwitch(isOn: false, theme: .folioPaper, target: receiver, action: #selector(ActionReceiver.fire(_:)))
        toggle.performClickForTesting()
        #expect(toggle.state == .on)
        #expect(receiver.count == 1)
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

private extension ChromeSwitch {
    func performClickForTesting() {
        _ = accessibilityPerformPress()
    }
}
