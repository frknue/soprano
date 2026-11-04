import AppKit
import Testing
@testable import Soprano

@MainActor
struct BrowserPaneAutomationTests {
    /// Mimics React's value tracker: an own `value`/`checked` property that
    /// remembers assignments, so an event only counts when the element's
    /// state differs from the last assigned one.
    private static let page = """
    <!doctype html>
    <label for="name">Name</label><input id="name">
    <input id="secret" type="password" value="hunter2">
    <label for="agree">Agree</label><input id="agree" type="checkbox">
    <script>
    window.seen = [];
    const track = (element, property, eventName) => {
      const native = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, property);
      let tracked = native.get.call(element);
      Object.defineProperty(element, property, {
        configurable: true,
        get() { return native.get.call(this); },
        set(value) { tracked = value; native.set.call(this, value); }
      });
      element.addEventListener(eventName, () => {
        const now = native.get.call(element);
        if (now !== tracked) { tracked = now; window.seen.push(`${element.id}=${now}`); }
      });
    };
    track(document.getElementById('name'), 'value', 'input');
    track(document.getElementById('agree'), 'checked', 'click');
    </script>
    """

    @Test func fillAndCheckReachFrameworkTrackedInputsAndSnapshotsHidePasswords() async throws {
        try await withPage { browser in
            #expect(try await run(browser, "fill", ["#name", "Ada"]) == "fill #name")
            #expect(try await run(browser, "check", ["#agree"]) == "check #agree")
            #expect(try await run(browser, "eval", ["window.seen.join(',')"]) == "name=Ada,agree=true")

            let snapshot = try await run(browser, "snapshot", [])
            #expect(snapshot.contains(#"textbox "Name""#))
            #expect(!snapshot.contains("hunter2"))
        }
    }

    @Test func sameDocumentNavigationsUpdateTheSavedURL() async throws {
        try await withPage { browser in
            var urls: [String] = []
            browser.onURLChanged = { urls.append($0) }
            _ = try await run(browser, "eval", ["history.pushState({}, '', '#settings'); location.href"])
            try await waitUntil { urls.last?.hasSuffix("#settings") == true }
            #expect(try await run(browser, "url", []).hasSuffix("#settings"))
        }
    }

    // MARK: - Helpers

    private func withPage(_ body: @MainActor (BrowserPaneView) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.html")
        try Data(Self.page.utf8).write(to: file)

        let browser = BrowserPaneView(
            target: BrowserTarget(paneId: "pane-1", tabId: "tab-1"),
            initialURL: file.absoluteString,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )
        browser.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: browser.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = browser
        defer { window.close() }

        var ready = false
        for _ in 0..<750 where !ready {
            ready = (try? await run(browser, "eval", ["String(Array.isArray(window.seen))"])) == "true"
            if !ready { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        try #require(ready, "The page never loaded")
        try await body(browser)
    }

    private func run(
        _ browser: BrowserPaneView,
        _ command: String,
        _ arguments: [String]
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            browser.performAutomation(command: command, arguments: arguments) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
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
