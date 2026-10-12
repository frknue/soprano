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

    @Test func aDiffTabShowsTheWholeFileInlineOrAlignedSideBySideAndFollowsTheFile() async throws {
        guard GitStatusReader.executableURL != nil else { return }
        try await withRepository { root in
            let fileURL = root.appendingPathComponent("app.txt")
            try Data("one\nthree\n".utf8).write(to: fileURL)
            let suiteName = "soprano-diff-tests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let themeManager = ThemeManager(themeId: "gruvbox-dark")
            let target = TerminalTarget(paneId: "pane", tabId: "tab")

            let inline = DiffPaneView(
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
            window.contentView = inline
            defer { window.contentView = nil }
            let inlineText = try #require(textViews(in: inline).first)
            try await waitUntil { inlineText.string == "one\ntwo\nthree\n" }

            // The file changes on disk: the open diff reloads.
            try Data("one\nthree\nfour\n".utf8).write(to: fileURL)
            try await waitUntil { inlineText.string == "one\ntwo\nthree\nfour\n" }

            defaults.set(true, forKey: DiffPaneView.sideBySideDefaultsKey)
            let sideBySide = DiffPaneView(
                target: target,
                fileURL: fileURL,
                staged: false,
                themeManager: themeManager,
                defaults: defaults
            )
            sideBySide.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            let sides = textViews(in: sideBySide)
            try #require(sides.count == 2)
            try await waitUntil { !sides[0].string.isEmpty }
            #expect(sides[0].string == "one\ntwo\nthree\n\n")
            #expect(sides[1].string == "one\n\nthree\nfour\n")
        }
    }

    // MARK: - Helpers

    private func textViews(in view: NSView) -> [DiffTextView] {
        view.subviews.flatMap { subview in
            ((subview as? DiffTextView).map { [$0] } ?? []) + textViews(in: subview)
        }
    }

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

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
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
