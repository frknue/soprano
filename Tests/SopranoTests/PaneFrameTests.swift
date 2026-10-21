import AppKit
import Testing
@testable import Soprano

/// Folio pane focus and attention (direction §6): the focused pane has a
/// raised header and the focus rule, the others are veiled, and an attention
/// pane is framed and never veiled.
@MainActor
struct PaneFrameTests {
    @Test func onlyTheFocusedPaneHasARaisedHeaderAndTheFocusRuleAndNoPaneHasAFrame() throws {
        let fixture = try PaneFixture(attentionOnCodex: false)
        let colors = fixture.themeManager.currentTheme.colors
        let focused = try fixture.container(fixture.focusedPaneId)
        let other = try fixture.container(fixture.codexPaneId)

        let focusedHeader = try fixture.header(in: focused)
        #expect(focusedHeader.layer?.backgroundColor == colors.raised.cgColor)
        #expect(focusedHeader.showsFocusMark)
        #expect(focused.layer?.borderWidth == 0)
        #expect(!focused.isVeiled)

        let otherHeader = try fixture.header(in: other)
        #expect(otherHeader.layer?.backgroundColor == colors.bgPanel.cgColor)
        #expect(!otherHeader.showsFocusMark)
        #expect(other.layer?.borderWidth == 0)
        #expect(other.isVeiled)
    }

    @Test func theFocusedTitleIsInkMediumAndOtherTitlesAreMuted() throws {
        let fixture = try PaneFixture(attentionOnCodex: false)
        let colors = fixture.themeManager.currentTheme.colors
        let focusedTitle = try fixture.visibleLabel("Claude Code", in: fixture.container(fixture.focusedPaneId))
        let otherTitle = try fixture.visibleLabel("Codex", in: fixture.container(fixture.codexPaneId))

        #expect(focusedTitle.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == ChromeFont.labelStrong)
        #expect(focusedTitle.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == colors.textPrimary)
        #expect(otherTitle.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == ChromeFont.label)
        #expect(otherTitle.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == colors.textMuted)
    }

    @Test func anAttentionPaneIsFramedNeverVeiledAndWashedInItsStatusColor() throws {
        let fixture = try PaneFixture(attentionOnCodex: true)
        let colors = fixture.themeManager.currentTheme.colors
        let codex = try fixture.container(fixture.codexPaneId)
        let header = try fixture.header(in: codex)

        #expect(codex.layer?.borderWidth == Chrome.attentionFrame)
        #expect(codex.layer?.borderColor == colors.attention.cgColor)
        #expect(!codex.isVeiled)
        #expect(!header.showsFocusMark)
        #expect(header.layer?.backgroundColor == PaneHeaderView.background(
            status: .needsInput,
            isFocused: false,
            needsAttention: true,
            colors: colors
        ).cgColor)
        #expect(fixture.visibleTexts(in: header).contains("NEEDS INPUT"))
        // The frame says attention; the header keeps its one status mark.
        let marks = fixture.descendants(of: header, as: ChromeStatusMark.self).filter { !$0.isHidden }
        #expect(marks.count == 1)
        #expect(marks.first?.color == colors.yellow)
    }

    @Test func headerWashesFollowTheComponentPrecedence() {
        let colors = AppTheme.folioPaper.colors
        let needsInputWash = colors.bgPanel.mixed(with: colors.yellow, fraction: 0.10)
        let attentionWash = colors.bgPanel.mixed(with: colors.attention, fraction: 0.10)

        #expect(PaneHeaderView.background(status: .needsInput, isFocused: true, needsAttention: true, colors: colors) == needsInputWash)
        #expect(PaneHeaderView.background(status: .working, isFocused: true, needsAttention: true, colors: colors) == attentionWash)
        #expect(PaneHeaderView.background(status: .working, isFocused: true, needsAttention: false, colors: colors) == colors.raised)
        #expect(PaneHeaderView.background(status: .working, isFocused: false, needsAttention: false, colors: colors) == colors.bgPanel)
    }

    @Test func theVeilNeverTakesClicksFromThePaneBody() throws {
        let fixture = try PaneFixture(attentionOnCodex: false)
        let codex = try fixture.container(fixture.codexPaneId)
        let body = try #require(fixture.bodies[fixture.codexPaneId])
        #expect(codex.isVeiled)

        let topmost = try #require(codex.subviews.last)
        #expect(topmost !== body)
        let pointInContainer = NSPoint(x: codex.bounds.midX, y: codex.isFlipped ? codex.bounds.maxY - 10 : 10)
        let pointInWindow = codex.convert(pointInContainer, to: nil)
        let hit = fixture.window.contentView?.hitTest(pointInWindow)
        #expect(hit === body)
    }

    @Test func paneTabsMarkTheActiveTabAndPrefixAttentionAndRunningTabs() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let firstTab = try #require(manager.panes[paneId]?.activeTab?.id)
        manager.renameTab(paneId, tabId: firstTab, to: "server")
        let agentTab = try #require(manager.addTabToPane(paneId, type: .terminal))
        manager.attachAgentIfNeeded(paneId: paneId, tabId: agentTab, profileId: "codex")
        manager.renameTab(paneId, tabId: agentTab, to: "Codex")
        manager.updateAgentStatus(paneId: paneId, tabId: agentTab, status: .waiting, needsAttention: true)
        manager.setRunningCommandTargets([TerminalTarget(paneId: paneId, tabId: firstTab)])
        manager.switchTab(paneId, index: 0)
        let themeManager = ThemeManager(themeId: "folio-paper")
        let colors = themeManager.currentTheme.colors

        let header = PaneHeaderView(paneId: paneId, agentManager: manager, themeManager: themeManager)
        let tabs = descendants(of: header, as: NSButton.self)
            .filter { $0.identifier?.rawValue != "pane-close-button" }
        #expect(tabs.map(\.attributedTitle.string) == ["● server", "● Codex"])

        let server = tabs[0].attributedTitle
        #expect(server.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == colors.runningCommand)
        #expect(server.attribute(.font, at: 2, effectiveRange: nil) as? NSFont == ChromeFont.labelStrong)
        #expect(server.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == colors.textPrimary)

        let codex = tabs[1].attributedTitle
        #expect(codex.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == colors.attention)
        #expect(codex.attribute(.font, at: 2, effectiveRange: nil) as? NSFont == ChromeFont.label)
        #expect(codex.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == colors.textMuted)
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}

/// A Claude pane (focused, left) beside a Codex pane, in a laid-out window.
@MainActor
private final class PaneFixture {
    let manager = AgentManager()
    let themeManager = ThemeManager(themeId: "folio-paper")
    let window: NSWindow
    let tree: SplitTreeView
    let focusedPaneId: String
    let codexPaneId: String
    private let bodyBox = BodyBox()
    var bodies: [String: NSView] { bodyBox.views }

    init(attentionOnCodex: Bool) throws {
        focusedPaneId = manager.activePaneId
        let claudeTab = try #require(manager.panes[focusedPaneId]?.activeTab?.id)
        manager.attachAgentIfNeeded(paneId: focusedPaneId, tabId: claudeTab, profileId: "claude-code")
        manager.renameTab(focusedPaneId, tabId: claudeTab, to: "Claude Code")

        codexPaneId = try #require(manager.splitPane(direction: .horizontal, paneId: focusedPaneId))
        let codexTab = try #require(manager.panes[codexPaneId]?.activeTab?.id)
        manager.attachAgentIfNeeded(paneId: codexPaneId, tabId: codexTab, profileId: "codex")
        manager.renameTab(codexPaneId, tabId: codexTab, to: "Codex")
        if attentionOnCodex {
            manager.updateAgentStatus(paneId: codexPaneId, tabId: codexTab, status: .waiting, needsAttention: true)
        }
        manager.focusPane(focusedPaneId)

        let bodyBox = bodyBox
        tree = SplitTreeView(
            agentManager: manager,
            themeManager: themeManager,
            terminalViewFactory: { target, _, _ in
                let view = NSView()
                bodyBox.views[target.paneId] = view
                return view
            }
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = tree
        tree.layoutSubtreeIfNeeded()
    }

    func container(_ paneId: String) throws -> PaneContainerView {
        try #require(descendants(of: tree, as: PaneContainerView.self).first { $0.paneId == paneId })
    }

    func header(in container: PaneContainerView) throws -> PaneHeaderView {
        try #require(descendants(of: container, as: PaneHeaderView.self).first)
    }

    func visibleLabel(_ text: String, in view: NSView) throws -> NSTextField {
        try #require(descendants(of: view, as: NSTextField.self).first { !$0.isHidden && $0.stringValue == text })
    }

    func visibleTexts(in view: NSView) -> [String] {
        descendants(of: view, as: NSTextField.self).filter { !$0.isHidden }.map(\.stringValue)
    }

    func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}

/// The terminal-body stand-ins the fixture's factory hands out, by pane.
@MainActor
private final class BodyBox {
    var views: [String: NSView] = [:]
}
