import AppKit
import Testing
@testable import Soprano

@MainActor
struct EditorTabTests {
    // MARK: - Opening

    @Test func filesOpenInASplitBesideTheFocusedPaneAndNeverCoverIt() throws {
        let manager = AgentManager()
        let terminalPaneId = manager.activePaneId
        let terminalTabId = try #require(manager.panes[terminalPaneId]?.activeTab?.id)

        let first = try #require(manager.openEditor(fileURL: URL(fileURLWithPath: "/tmp/a.swift"), preview: true))

        #expect(first.paneId != terminalPaneId)
        #expect(manager.panes[terminalPaneId]?.tabs.map(\.id) == [terminalTabId])
        #expect(manager.layout?.orderedLeafIds == [terminalPaneId, first.paneId])
        #expect(manager.activePaneId == first.paneId)

        // Back in the terminal, the next file joins the existing split.
        manager.focusPane(terminalPaneId)
        let second = try #require(manager.openEditor(fileURL: URL(fileURLWithPath: "/tmp/b.swift"), preview: false))
        #expect(second.paneId == first.paneId)
        #expect(manager.panes[terminalPaneId]?.tabs.map(\.id) == [terminalTabId])
        #expect(manager.layout?.orderedLeafIds.count == 2)
    }

    @Test func previewTabsAreReusedWhileKeptTabsStay() throws {
        let manager = AgentManager()
        let a = URL(fileURLWithPath: "/tmp/project/a.swift")
        let b = URL(fileURLWithPath: "/tmp/project/b.swift")
        let c = URL(fileURLWithPath: "/tmp/project/c.swift")

        let first = try #require(manager.openEditor(fileURL: a, preview: true))
        let paneId = first.paneId
        #expect(editorTabs(manager, paneId).map(\.title) == ["a.swift"])
        #expect(editorTabs(manager, paneId).first?.isEditorPreview == true)

        let second = try #require(manager.openEditor(fileURL: b, preview: true))
        #expect(second.paneId == paneId)
        #expect(editorTabs(manager, paneId).map(\.title) == ["b.swift"])
        #expect(second.tabId != first.tabId)

        let kept = try #require(manager.openEditor(fileURL: b, preview: false))
        #expect(kept.tabId == second.tabId)
        #expect(editorTabs(manager, paneId).first?.isEditorPreview == false)

        _ = try #require(manager.openEditor(fileURL: c, preview: true))
        #expect(editorTabs(manager, paneId).map(\.title) == ["b.swift", "c.swift"])

        let refocused = try #require(manager.openEditor(fileURL: b, preview: true))
        #expect(refocused.tabId == second.tabId)
        #expect(manager.panes[paneId]?.activeTab?.id == second.tabId)
        #expect(editorTabs(manager, paneId).count == 2)
    }

    @Test func editingKeepsAPreviewTab() throws {
        let manager = AgentManager()
        let target = try #require(manager.openEditor(fileURL: URL(fileURLWithPath: "/tmp/x.txt"), preview: true))

        manager.keepEditorTab(paneId: target.paneId, tabId: target.tabId)
        _ = manager.openEditor(fileURL: URL(fileURLWithPath: "/tmp/y.txt"), preview: true)

        #expect(editorTabs(manager, target.paneId).map(\.title) == ["x.txt", "y.txt"])
    }

    @Test func aFullFilePaneGetsANewSplitAndAFullWindowFallsBackToATab() throws {
        let manager = AgentManager()
        let first = try #require(manager.openEditor(fileURL: URL(fileURLWithPath: "/tmp/f0.txt"), preview: false))
        for index in 1..<PaneState.maxTabsPerPane {
            _ = manager.openEditor(fileURL: URL(fileURLWithPath: "/tmp/f\(index).txt"), preview: false)
        }
        #expect(manager.panes[first.paneId]?.tabs.count == PaneState.maxTabsPerPane)

        let overflow = try #require(manager.openEditor(fileURL: URL(fileURLWithPath: "/tmp/z.txt"), preview: true))
        #expect(overflow.paneId != first.paneId)

        // No room for another pane: the file becomes a tab of the focused pane.
        let crowded = AgentManager()
        while crowded.canAddPane(to: crowded.activeWindowId) {
            _ = crowded.spawnTerminal()
        }
        let focusedPaneId = crowded.activePaneId
        let target = try #require(crowded.openEditor(fileURL: URL(fileURLWithPath: "/tmp/z.txt"), preview: true))
        #expect(target.paneId == focusedPaneId)
        #expect(crowded.panes[focusedPaneId]?.activeTab?.isEditor == true)
    }

    @Test func renamingAFolderRepointsTheEditorAndReaderTabsInsideIt() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let editor = try #require(manager.openEditor(
            fileURL: URL(fileURLWithPath: "/tmp/project/src/app.swift"),
            preview: false,
            in: paneId
        ))
        let reader = try #require(manager.previewMarkdown(
            fileURL: URL(fileURLWithPath: "/tmp/project/src/README.md"),
            in: paneId
        ))
        let other = try #require(manager.openEditor(
            fileURL: URL(fileURLWithPath: "/tmp/project/srcs.swift"),
            preview: false,
            in: paneId
        ))
        var documentChanges: [TerminalTarget] = []
        manager.addObserver(id: "test") { change in
            if case .document(let target) = change {
                documentChanges.append(target)
            }
        }

        manager.relocateFileTabs(
            from: URL(fileURLWithPath: "/tmp/project/src"),
            to: URL(fileURLWithPath: "/tmp/project/lib")
        )

        let tabs = try #require(manager.panes[paneId]?.tabs)
        #expect(tabs.first { $0.id == editor.tabId }?.url == "file:///tmp/project/lib/app.swift")
        #expect(tabs.first { $0.id == reader }?.url == "file:///tmp/project/lib/README.md")
        #expect(tabs.first { $0.id == other.tabId }?.url == "file:///tmp/project/srcs.swift")
        #expect(Set(documentChanges.map(\.tabId)) == [editor.tabId, reader])
    }

    // MARK: - Close Confirmation

    @Test func closingAsksOnceAboutExactlyTheTabsThatGo() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let terminalTabId = try #require(manager.panes[paneId]?.activeTab?.id)
        let editor = try #require(manager.openEditor(fileURL: URL(fileURLWithPath: "/tmp/a.txt"), preview: false, in: paneId))
        var questions: [Set<TerminalTarget>] = []
        var allow = false
        manager.closeConfirmation = { targets in
            questions.append(Set(targets))
            return allow
        }

        manager.removeTabFromPane(paneId, tabId: editor.tabId)
        #expect(questions == [[editor]])
        #expect(manager.panes[paneId]?.tabs.count == 2)

        manager.closePane(paneId)
        #expect(questions.last == [editor, TerminalTarget(paneId: paneId, tabId: terminalTabId)])
        #expect(manager.panes[paneId] != nil)

        // The window's last pane takes the window with it: still one question.
        questions.removeAll()
        allow = true
        let windowId = manager.activeWindowId
        manager.closePane(paneId)
        #expect(questions.count == 1)
        #expect(manager.panes[paneId] == nil)
        #expect(manager.windows[windowId] == nil)
    }

    @Test func closingAnInnerWorkspaceAsksOnlyAboutItsPanes() throws {
        let manager = AgentManager()
        let outerPaneId = manager.activePaneId
        let outerTabId = try #require(manager.panes[outerPaneId]?.activeTab?.id)
        _ = try #require(manager.goIn(outerPaneId))
        let innerPaneId = manager.activePaneId
        #expect(innerPaneId != outerPaneId)
        let innerTabs = Set(try #require(manager.panes[innerPaneId]).tabs.map {
            TerminalTarget(paneId: innerPaneId, tabId: $0.id)
        })
        var questions: [Set<TerminalTarget>] = []
        manager.closeConfirmation = { targets in
            questions.append(Set(targets))
            return false
        }

        // Cancelled, but handled: the caller must not close the pane instead.
        #expect(manager.closeActiveDepthLayer(innerPaneId))
        manager.closePane(innerPaneId)

        #expect(questions == [innerTabs, innerTabs])
        #expect(!questions.contains { $0.contains(TerminalTarget(paneId: outerPaneId, tabId: outerTabId)) })
        #expect(manager.panes[innerPaneId] != nil)
    }

    @Test func closingAWindowOrSessionAsksAboutAllItsTabs() throws {
        let manager = AgentManager()
        let firstWindowId = manager.activeWindowId
        let firstPaneId = manager.activePaneId
        _ = manager.openEditor(fileURL: URL(fileURLWithPath: "/tmp/a.txt"), preview: false, in: firstPaneId)
        _ = try #require(manager.createWindow())
        var questions: [Int] = []
        manager.closeConfirmation = { targets in
            questions.append(targets.count)
            return false
        }

        manager.closeWindow(firstWindowId)
        manager.closeSession(manager.activeSessionId)

        #expect(questions == [2, 3])
        #expect(manager.windows[firstWindowId] != nil)
        #expect(manager.panes[firstPaneId]?.tabs.count == 2)
    }

    // MARK: - Editor In The Split Tree

    @Test func anEditorTabEditsSavesAndStopsBeingAPreview() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-editor-tab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("main.swift")
        try Data("let a = 1\n".utf8).write(to: fileURL)

        let (controller, manager, suiteName) = try makeController()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        // Released by ARC, not by closing.
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }

        let target = try #require(manager.openEditor(fileURL: fileURL, preview: true))
        controller.view.layoutSubtreeIfNeeded()
        let editor = try #require(descendants(of: controller.view, as: EditorPaneView.self).first)
        #expect(editor.target == target)
        #expect(editor.textView.string == "let a = 1\n")
        try await waitUntil { !editor.document.tokens.isEmpty }
        #expect(editor.document.tokens.first?.kind == .keyword)

        editor.textView.setSelectedRange(NSRange(location: 8, length: 1))
        editor.textView.insertText("2", replacementRange: editor.textView.selectedRange())
        try await waitUntil { manager.panes[target.paneId]?.activeTab?.title == "main.swift ●" }
        #expect(manager.panes[target.paneId]?.activeTab?.isEditorPreview == false)

        let commandS = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "s",
            charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1
        ))
        // Elsewhere ⌘S passes on to whatever has the keyboard.
        window.makeFirstResponder(nil)
        #expect(!editor.performKeyEquivalent(with: commandS))
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let a = 1\n")

        window.makeFirstResponder(editor.textView)
        #expect(editor.performKeyEquivalent(with: commandS))
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let a = 2\n")
        try await waitUntil { manager.panes[target.paneId]?.activeTab?.title == "main.swift" }

        #expect(MainWindowController.focusedContent(of: editor.textView) == .editor)
        #expect(MainWindowController.focusedContent(of: controller.view) == .other)
    }

    // MARK: - Shortcuts

    @Test func focusedPanesKeepOnlyTheChordsTheyOwn() {
        #expect(KeybindingFocusedContent.browser.ownsChord(key: "l", flags: .command))
        #expect(!KeybindingFocusedContent.browser.ownsChord(key: "l", flags: [.command, .shift]))
        #expect(!KeybindingFocusedContent.browser.ownsChord(key: "f", flags: .command))
        #expect(KeybindingFocusedContent.editor.ownsChord(key: "f", flags: .command))
        #expect(KeybindingFocusedContent.editor.ownsChord(key: "g", flags: [.command, .shift]))
        #expect(!KeybindingFocusedContent.editor.ownsChord(key: "l", flags: .command))
        #expect(!KeybindingFocusedContent.other.ownsChord(key: "l", flags: .command))

        let binding = DefaultKeybindings.config.bindings.first { $0.id == "toggle-right-sidebar" }
        #expect(binding?.key == "l")
        #expect(binding?.meta == true)
        #expect(binding?.shift != true)
    }

    // MARK: - Helpers

    private func editorTabs(_ manager: AgentManager, _ paneId: String) -> [PaneTab] {
        manager.panes[paneId]?.tabs.filter(\.isEditor) ?? []
    }

    private func makeController() throws -> (MainContentViewController, AgentManager, String) {
        let suiteName = "soprano-editor-tab-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(false, forKey: "soprano-right-sidebar-visible")
        let manager = AgentManager()
        let controller = MainContentViewController(
            agentManager: manager,
            sessionManager: SessionManager(agentManager: manager, defaults: defaults),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor(),
            defaults: defaults,
            splitTreeViewFactory: { manager, themeManager in
                SplitTreeView(
                    agentManager: manager,
                    themeManager: themeManager,
                    terminalViewFactory: { _, _, _ in NSView() },
                    destroyTerminalView: { _ in },
                    restartTerminalView: { _, _ in true },
                    terminalViewHasLiveSurface: { _ in false },
                    scheduleCodexReadiness: { _ in }
                )
            }
        )
        controller.loadViewIfNeeded()
        return (controller, manager, suiteName)
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            ((subview as? T).map { [$0] } ?? []) + descendants(of: subview, as: type)
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("Timed out")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
