import AppKit
import Testing
@testable import Soprano

@MainActor
struct SourceControlViewTests {
    @Test func theListShowsTheActivePanesChangesAndFollowsTheWorkingTreeAndIndex() async throws {
        guard GitStatusReader.executableURL != nil else { return }
        try await withRepository { root in
            let agentManager = AgentManager()
            let paneId = agentManager.activePaneId
            let tabId = try #require(agentManager.panes[paneId]?.activeTab?.id)
            agentManager.updateWorkingDirectory(paneId: paneId, tabId: tabId, to: root.path)
            let view = SourceControlView(
                agentManager: agentManager,
                themeManager: ThemeManager(themeId: "gruvbox-dark")
            )
            view.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
            view.setActive(true)
            defer { view.setActive(false) }

            #expect(view.rootURL?.path == root.path)
            try await waitUntil { view.changeList.branch != nil }
            #expect(view.changeList.changes.isEmpty)

            // Edits by other programs show up on their own, and so does staging.
            try Data("one\nTWO\n".utf8).write(to: root.appendingPathComponent("app.txt"))
            try await waitUntil { view.changeList.changes.map(\.area) == [.unstaged] }
            try git(["add", "app.txt"], in: root)
            try await waitUntil { view.changeList.changes.map(\.area) == [.staged] }
            #expect(view.changeList.changes.first?.linesAdded == 1)
            #expect(view.changeList.changes.first?.linesDeleted == 2)
        }
    }

    @Test func aDiffTabListsTheChangesStackedOrSplitAndFollowsTheFile() async throws {
        guard GitStatusReader.executableURL != nil else { return }
        try await withRepository { root in
            let fileURL = root.appendingPathComponent("app.txt")
            try Data("one\nthree\n".utf8).write(to: fileURL)
            let suiteName = "soprano-diff-tests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let themeManager = ThemeManager(themeId: "gruvbox-dark")
            let target = TerminalTarget(paneId: "pane", tabId: "tab")

            let stacked = DiffPaneView(
                target: target,
                fileURL: fileURL,
                staged: false,
                themeManager: themeManager,
                defaults: defaults
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            window.contentView = stacked
            defer { window.contentView = nil }
            try await waitUntil { stacked.document?.lines.map(\.text) == ["one", "two", "three"] }
            #expect(stacked.document?.path == "app.txt")
            #expect(stacked.layoutMode == .unified)
            // The file opens with its change: the block's range heads it.
            #expect(stacked.list.rows == [
                .header,
                .fold(SurfaceDiffFold(id: -1, rows: 0..<0, range: "@@ -1,3 +1,2 @@", section: "")),
                .line(0), .line(1), .line(2),
                .end,
            ])
            #expect(stacked.list.changeRows == [3])
            #expect(stacked.tableView.numberOfRows == stacked.list.rows.count)

            // Pressing a line and dragging selects whole lines; ⌘C copies their text without
            // markers or numbers. ⇧-click moves the end; the strip and header copy nothing.
            stacked.beginSelection(at: 3, x: 40, extending: false)
            #expect(stacked.selectedText() == "two")
            stacked.extendSelection(to: 4)
            #expect(stacked.selectedText() == "two\nthree")
            stacked.beginSelection(at: 0, x: 40, extending: true)
            #expect(stacked.selection?.rows == 0...3)
            #expect(stacked.selectedText() == "one\ntwo")

            // The file changes on disk: the open diff reloads.
            try Data("one\nthree\nfour\n".utf8).write(to: fileURL)
            try await waitUntil { stacked.document?.lines.map(\.text) == ["one", "two", "three", "four"] }

            defaults.set(true, forKey: DiffPaneView.sideBySideDefaultsKey)
            let split = DiffPaneView(
                target: target,
                fileURL: fileURL,
                staged: false,
                themeManager: themeManager,
                defaults: defaults
            )
            split.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            #expect(split.layoutMode == .split)
            try await waitUntil { split.document != nil }
            let document = try #require(split.document)
            #expect(document.old.rows.map(\.kind) == [.context, .removed, .context, .filler])
            #expect(document.new.rows.map(\.kind) == [.context, .filler, .context, .added])
            #expect(split.list.rows.filter { if case .pair = $0 { true } else { false } }.count == 4)
            #expect(split.list.changeRows.count == 2)
        }
    }

    // MARK: - Helpers

    /// A repository whose `app.txt` is committed as "one\ntwo\nthree\n".
    private func withRepository(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-source-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q"], in: root)
        try Data("one\ntwo\nthree\n".utf8).write(to: root.appendingPathComponent("app.txt"))
        try git(["add", "app.txt"], in: root)
        try git(
            ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
             "-c", "core.hooksPath=/dev/null", "commit", "-qm", "init"],
            in: root
        )
        try await body(root)
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = GitStatusReader.executableURL
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
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
