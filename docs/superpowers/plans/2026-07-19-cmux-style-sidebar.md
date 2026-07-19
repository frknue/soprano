# cmux-Style Pane List Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the VSCode-style activity-bar sidebar with a cmux-style persistent pane list (status dot, title, tab badge, close, git branch per row; `+` spawn menu; sessions/settings footer) toggled entirely on/off with ⌘E, per `docs/superpowers/specs/2026-07-19-cmux-style-sidebar-design.md`.

**Architecture:** A new Foundation-only `GitBranchMonitor` (Controllers/) resolves and file-watches `.git/HEAD` for pane cwds. `SidebarView` is rewritten as header + scrolling row list + footer. `MainContentViewController` keeps its animated width-constraint mechanism but toggles 0 ↔ 220pt and persists visibility. The monitor is created in `AppDelegate` and threaded through `MainWindowController` → `MainContentViewController` → `SidebarView`.

**Tech Stack:** Swift 6 / AppKit, no third-party deps. No in-app test framework: `GitBranchMonitor` is verified by a standalone compiled harness in the scratchpad; UI tasks verify by clean build + screenshot via the driver harness below.

## Global Constraints

- Build ALWAYS with Homebrew Swift: `PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build` — system CLT Swift has broken SPM.
- Code conventions (CLAUDE.md): `final class` for all concrete classes; `@available(*, unavailable) required init?(coder:)` on all NSView subclasses; `translatesAutoresizingMaskIntoConstraints = false` + `NSLayoutConstraint.activate([...])`; `@unchecked Sendable` instead of `@MainActor` (all classes are main-thread-only); 4-space indent; trailing commas in multi-line structures; multi-class-per-file for self-contained features.
- Theme tokens come from `AppTheme.colors` (`Sources/Soprano/Config/Theme.swift`): `bgBase, bgPanel, bgRaised, bgOverlay, textPrimary, textMuted, accent, accentStrong, borderSubtle, borderStrong, success, danger, blue, cyan, yellow, gray`.
- Do NOT change: `KeybindingManager` (the `toggle-sidebar` binding, ⌘E, already routes to `keybindingToggleSidebar()` → `mainContentVC?.toggleSidebar()`), `SessionManager`, `StatusBarView`, `SplitTreeView`, `PaneState`, `AgentManager`, the command palette.
- New UserDefaults key uses the `soprano-` prefix: `soprano-sidebar-visible` (Bool, default true).
- **Spec addendum** (applied in Task 2): branch resolution falls back `tab.cwd` → profile `cwd` → `FileManager.default.currentDirectoryPath`. Default agent profiles have no `cwd`, and ghostty spawns with `workingDirectory` unset inherit the app process's cwd — without this final fallback the branch line would never appear for normally-spawned panes.
- Kill any running app instance before rebuilding/relaunching: `pkill -x Soprano`.

## Verification Harness

The scratchpad is `/private/tmp/claude-501/-Users-furkanulker-git-private-soprano/33105055-4294-4ee0-82c5-5eb20ce13c03/scratchpad` (call it `$SCRATCH`). It starts empty; Task 2 Step 1 creates the two helper tools. `driver` posts key events to a pid (needs Accessibility permission for the invoking terminal); `allwin` lists a pid's windows (window names need Screen Recording permission).

`$SCRATCH/driver.swift`:

```swift
import Cocoa

// usage: driver key <pid> <keycode> [cmd] [shift] [alt] [ctrl]
let args = CommandLine.arguments
guard args.count >= 4, args[1] == "key", let pid = pid_t(args[2]), let code = UInt16(args[3]) else {
    print("usage: driver key <pid> <keycode> [cmd|shift|alt|ctrl ...]")
    exit(1)
}
var flags: CGEventFlags = []
for mod in args.dropFirst(4) {
    switch mod {
    case "cmd": flags.insert(.maskCommand)
    case "shift": flags.insert(.maskShift)
    case "alt": flags.insert(.maskAlternate)
    case "ctrl": flags.insert(.maskControl)
    default: break
    }
}
let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
down.flags = flags
down.postToPid(pid)
usleep(50_000)
let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!
up.flags = flags
up.postToPid(pid)
```

`$SCRATCH/allwin.swift`:

```swift
import Cocoa

// usage: allwin <pid>
guard CommandLine.arguments.count >= 2, let pid = Int32(CommandLine.arguments[1]) else {
    print("usage: allwin <pid>")
    exit(1)
}
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for info in list {
    guard let owner = info[kCGWindowOwnerPID as String] as? Int32, owner == pid else { continue }
    let id = info[kCGWindowNumber as String] as? Int ?? 0
    let name = info[kCGWindowName as String] as? String ?? ""
    print("id=\(id) name=\(name)")
}
```

Build both:

```bash
SCRATCH=/private/tmp/claude-501/-Users-furkanulker-git-private-soprano/33105055-4294-4ee0-82c5-5eb20ce13c03/scratchpad
/opt/homebrew/opt/swift/bin/swiftc -sdk "$(xcrun --show-sdk-path)" -O -o "$SCRATCH/driver" "$SCRATCH/driver.swift"
/opt/homebrew/opt/swift/bin/swiftc -sdk "$(xcrun --show-sdk-path)" -O -o "$SCRATCH/allwin" "$SCRATCH/allwin.swift"
```

Standard verification cycle (background launch; restores the user's focus after the launch blip):

```bash
SCRATCH=/private/tmp/claude-501/-Users-furkanulker-git-private-soprano/33105055-4294-4ee0-82c5-5eb20ce13c03/scratchpad
cd /Users/furkanulker/git/private/soprano
PREV=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
pkill -x Soprano; sleep 1
.build/debug/Soprano > /dev/null 2>&1 &
sleep 3
osascript -e "tell application \"$PREV\" to activate" || true
PID=$(pgrep -x Soprano | head -1)
WID=$("$SCRATCH/allwin" "$PID" | grep "name=Soprano" | sed -E 's/id=([0-9]+).*/\1/')
screencapture -x -o -l "$WID" "$SCRATCH/verify-<label>.png"
```

Read the PNG and compare against the task's expected-appearance checklist. Kill the app afterwards: `pkill -x Soprano`. Useful key codes: E=14, comma=43 (⌘, opens settings), down-arrow=125, return=36, escape=53.

## File Structure

- **Create** `Sources/Soprano/Controllers/GitBranchMonitor.swift` — Foundation-only branch resolution + HEAD watching. No AppKit imports; this is what lets the standalone harness compile it.
- **Rewrite** `Sources/Soprano/Views/SidebarView.swift` — header ("PANES" + `+` menu), pane row list (`SidebarPaneRowView`, two-line), footer (sessions menu + settings gear). `SidebarSection`, `SidebarActionRowView`, and the activity bar are deleted.
- **Modify** `Sources/Soprano/App/MainContentViewController.swift` — 0 ↔ 220pt toggle with persistence; drop `onExpandedChanged`; thread the monitor.
- **Modify** `Sources/Soprano/App/MainWindowController.swift` — accept + forward `gitBranchMonitor`.
- **Modify** `Sources/Soprano/App/AppDelegate.swift` — create `GitBranchMonitor`.
- **Modify** `docs/superpowers/specs/2026-07-19-cmux-style-sidebar-design.md` — one-line cwd-fallback addendum.

---

### Task 1: GitBranchMonitor with standalone harness

**Files:**
- Create: `Sources/Soprano/Controllers/GitBranchMonitor.swift`
- Test: `$SCRATCH/git-monitor-test/main.swift` (scratchpad harness, not committed)

**Interfaces:**
- Consumes: nothing from the app (Foundation only).
- Produces (used by Tasks 2–3):
  - `final class GitBranchMonitor: @unchecked Sendable`
  - `init()` (no arguments)
  - `var onChange: (() -> Void)?` — fired on the main queue when any watched HEAD changes
  - `func branch(for cwd: String) -> String?` — cached; nil when not in a repo
  - `func setWatchedPaths(_ paths: [String])` — reconcile watchers with the given cwds
  - `static func resolveHeadPath(startingAt path: String) -> String?` (exposed for the harness)
  - `static func parseHead(at headPath: String) -> String?` (exposed for the harness)

- [ ] **Step 1: Write the failing harness**

Write `$SCRATCH/git-monitor-test/main.swift`:

```swift
import Foundation

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

@discardableResult
func sh(_ command: String, cwd: String? = nil) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", command]
    if let cwd {
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try! process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
}

let root = NSTemporaryDirectory() + "git-monitor-test-\(ProcessInfo.processInfo.processIdentifier)"
try? FileManager.default.removeItem(atPath: root)
try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

// 1. Non-repo directory -> nil
let plain = root + "/plain"
try! FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
check(GitBranchMonitor().branch(for: plain) == nil, "non-repo returns nil")

// 2. Repo on a branch
let repo = root + "/repo"
try! FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
sh("git init -b main && git -c user.email=t@t -c user.name=t commit --allow-empty -m init", cwd: repo)
check(GitBranchMonitor().branch(for: repo) == "main", "repo on main returns main")

// 3. Nested subdirectory resolves to the same repo
let nested = repo + "/a/b"
try! FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
check(GitBranchMonitor().branch(for: nested) == "main", "nested cwd returns main")

// 4. Detached HEAD -> 7-char short sha
let sha = sh("git rev-parse HEAD", cwd: repo)
sh("git checkout --detach", cwd: repo)
check(GitBranchMonitor().branch(for: repo) == String(sha.prefix(7)), "detached HEAD returns short sha")
sh("git checkout main", cwd: repo)

// 5. Worktree (.git file with gitdir: pointer)
sh("git worktree add -b feature-wt ../wt", cwd: repo)
let wt = root + "/wt"
check(GitBranchMonitor().branch(for: wt) == "feature-wt", "worktree returns its branch")

// 6. Watcher fires on checkout and the cache updates
let watchMonitor = GitBranchMonitor()
_ = watchMonitor.branch(for: repo)
watchMonitor.setWatchedPaths([repo])
var changed = false
watchMonitor.onChange = { changed = true }
sh("git checkout -b feature-live", cwd: repo)
let deadline = Date().addingTimeInterval(5)
while !changed && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
check(changed, "watcher fired on checkout")
check(watchMonitor.branch(for: repo) == "feature-live", "branch updated after checkout")

try? FileManager.default.removeItem(atPath: root)
if failures > 0 {
    print("\(failures) FAILURES")
    exit(1)
}
print("ALL PASS")
```

- [ ] **Step 2: Run harness to verify it fails**

```bash
SCRATCH=/private/tmp/claude-501/-Users-furkanulker-git-private-soprano/33105055-4294-4ee0-82c5-5eb20ce13c03/scratchpad
cd /Users/furkanulker/git/private/soprano
/opt/homebrew/opt/swift/bin/swiftc \
    Sources/Soprano/Controllers/GitBranchMonitor.swift \
    "$SCRATCH/git-monitor-test/main.swift" \
    -o "$SCRATCH/git-monitor-test/harness"
```

Expected: FAIL — `error: ... GitBranchMonitor.swift: No such file or directory` (the monitor doesn't exist yet).

- [ ] **Step 3: Write GitBranchMonitor**

Create `Sources/Soprano/Controllers/GitBranchMonitor.swift`:

```swift
import Foundation

/// Resolves and watches git branch names for pane working directories.
/// Main-thread-only like the other managers; watcher events are delivered
/// on the main queue. Foundation-only so it can be compiled standalone.
final class GitBranchMonitor: @unchecked Sendable {
    /// Fired whenever a watched HEAD changes on disk.
    var onChange: (() -> Void)?

    /// cwd -> resolved HEAD file path (nil = resolved as "not inside a repo").
    private var headPathByCwd: [String: String?] = [:]
    /// HEAD path -> cached branch name.
    private var branchByHeadPath: [String: String] = [:]
    /// HEAD path -> active file watcher.
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]

    deinit {
        for watcher in watchers.values {
            watcher.cancel()
        }
    }

    // MARK: - Public API

    /// Current branch for a working directory; nil when not in a git repo.
    func branch(for cwd: String) -> String? {
        let headPath: String?
        if let cached = headPathByCwd[cwd] {
            headPath = cached
        } else {
            headPath = Self.resolveHeadPath(startingAt: cwd)
            headPathByCwd[cwd] = headPath
        }
        guard let headPath else { return nil }
        if let cached = branchByHeadPath[headPath] {
            return cached
        }
        let branch = Self.parseHead(at: headPath)
        branchByHeadPath[headPath] = branch
        return branch
    }

    /// Reconcile watchers with the current set of pane working directories.
    func setWatchedPaths(_ paths: [String]) {
        var newHeadPathByCwd: [String: String?] = [:]
        var neededHeadPaths = Set<String>()
        for cwd in Set(paths) {
            let headPath: String?
            if let cached = headPathByCwd[cwd] {
                headPath = cached
            } else {
                headPath = Self.resolveHeadPath(startingAt: cwd)
            }
            newHeadPathByCwd[cwd] = headPath
            if let headPath {
                neededHeadPaths.insert(headPath)
            }
        }
        headPathByCwd = newHeadPathByCwd

        for (headPath, watcher) in watchers where !neededHeadPaths.contains(headPath) {
            watcher.cancel()
            watchers.removeValue(forKey: headPath)
            branchByHeadPath.removeValue(forKey: headPath)
        }
        for headPath in neededHeadPaths where watchers[headPath] == nil {
            addWatcher(for: headPath)
            if watchers[headPath] == nil {
                // Watcher couldn't be established (unreadable HEAD, exhausted
                // fds): drop the cache so each rebuild re-reads instead of
                // serving a stale branch forever.
                branchByHeadPath.removeValue(forKey: headPath)
            }
        }
    }

    // MARK: - Watching

    private func addWatcher(for headPath: String) {
        let fd = open(headPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.headChanged(headPath)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        watchers[headPath] = source
    }

    private func headChanged(_ headPath: String) {
        // git updates HEAD via atomic rename, which orphans the watched fd —
        // drop the watcher and re-arm on the new inode.
        watchers[headPath]?.cancel()
        watchers.removeValue(forKey: headPath)
        branchByHeadPath.removeValue(forKey: headPath)
        if FileManager.default.fileExists(atPath: headPath) {
            addWatcher(for: headPath)
        }
        onChange?()
    }

    // MARK: - Resolution & Parsing

    /// Walk up from `path` to the repo's HEAD file. Handles `.git`
    /// directories and `.git` files containing a `gitdir:` pointer
    /// (worktrees and submodules).
    static func resolveHeadPath(startingAt path: String) -> String? {
        var dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let fm = FileManager.default
        while true {
            let gitURL = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return gitURL.appendingPathComponent("HEAD").path
                }
                guard let contents = try? String(contentsOf: gitURL, encoding: .utf8) else {
                    return nil
                }
                let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("gitdir:") else { return nil }
                let target = line.dropFirst("gitdir:".count)
                    .trimmingCharacters(in: .whitespaces)
                let gitDirURL = target.hasPrefix("/")
                    ? URL(fileURLWithPath: target)
                    : dir.appendingPathComponent(target).standardizedFileURL
                return gitDirURL.appendingPathComponent("HEAD").path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path {
                return nil
            }
            dir = parent
        }
    }

    /// "ref: refs/heads/main" -> "main"; detached HEAD -> 7-char sha prefix.
    static func parseHead(at headPath: String) -> String? {
        guard let contents = try? String(contentsOfFile: headPath, encoding: .utf8) else {
            return nil
        }
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: refs/heads/") {
            let name = String(line.dropFirst("ref: refs/heads/".count))
            return name.isEmpty ? nil : name
        }
        if line.hasPrefix("ref: ") {
            return line.split(separator: "/").last.map(String.init)
        }
        guard line.count >= 7 else { return nil }
        return String(line.prefix(7))
    }
}
```

Note: `branchByHeadPath[headPath] = branch` with a nil branch removes the entry — nil results are deliberately never cached (cheap to re-derive, self-healing when a repo appears later).

- [ ] **Step 4: Run harness to verify it passes**

Re-run the Step 2 compile command, then:

```bash
"$SCRATCH/git-monitor-test/harness"
```

Expected: 8 `PASS` lines and `ALL PASS`, exit code 0.

- [ ] **Step 5: Verify the app still builds**

```bash
cd /Users/furkanulker/git/private/soprano
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build
```

Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/Soprano/Controllers/GitBranchMonitor.swift
git commit -m "feat: add GitBranchMonitor for sidebar branch display"
```

---

### Task 2: Sidebar rewrite + toggle/persistence + wiring

**Files:**
- Rewrite: `Sources/Soprano/Views/SidebarView.swift` (full file replacement)
- Modify: `Sources/Soprano/App/MainContentViewController.swift`
- Modify: `Sources/Soprano/App/MainWindowController.swift`
- Modify: `Sources/Soprano/App/AppDelegate.swift`
- Modify: `docs/superpowers/specs/2026-07-19-cmux-style-sidebar-design.md`

**Interfaces:**
- Consumes: `GitBranchMonitor` (Task 1: `init()`, `branch(for:) -> String?`, `setWatchedPaths(_:)`, `onChange`); existing `AgentManager` (`panes: [String: PaneState]`, `activePaneId: String`, `focusPane(_: String)`, `closePane(_: String)`, `addObserver(id:handler:)`, `removeObserver(id:)`); `ThemeManager.currentTheme`; `DefaultAgents.profile(for:) -> AgentProfile?`.
- Produces (used by Task 3):
  - `SidebarView.init(agentManager: AgentManager, sessionManager: SessionManager, themeManager: ThemeManager, gitBranchMonitor: GitBranchMonitor)`
  - `SidebarView.onSettingsRequested: (() -> Void)?` (unchanged)
  - `SidebarView.refreshTheme()` (unchanged)
  - private helpers Task 3 extends: `makeIconButton(symbolName:accessibilityLabel:action:) -> NSButton`, `contentContainer`, `headerLabel`, `footerView`, `settingsButton`
  - `MainContentViewController.toggleSidebar()` (unchanged name, new hidden/shown semantics)
  - `MainContentViewController.init(agentManager:sessionManager:themeManager:gitBranchMonitor:onSettingsRequested:)`
  - `MainWindowController.init(agentManager:sessionManager:themeManager:gitBranchMonitor:settings:)`

- [ ] **Step 1: Build the verification harness tools**

Write `$SCRATCH/driver.swift` and `$SCRATCH/allwin.swift` from the Verification Harness section and compile both with the commands there. Run `"$SCRATCH/allwin" $$` — expected: prints nothing (the shell has no windows) and exits 0, proving the binary runs.

- [ ] **Step 2: Rewrite SidebarView.swift**

Replace the entire contents of `Sources/Soprano/Views/SidebarView.swift` with:

```swift
import AppKit

/// cmux-style persistent sidebar: PANES header, rich pane rows, footer.
final class SidebarView: NSView {
    let agentManager: AgentManager
    let sessionManager: SessionManager
    let themeManager: ThemeManager
    let gitBranchMonitor: GitBranchMonitor

    var onSettingsRequested: (() -> Void)?

    static let width: CGFloat = 220

    private var contentContainer: NSView!
    private var headerLabel: NSTextField!
    private var scrollView: NSScrollView!
    private var listContentView: NSView!
    private var rowsStack: NSStackView!
    private var footerView: NSView!
    private var footerSeparator: NSView!
    private var trailingBorder: NSView!
    private var settingsButton: NSButton!

    init(
        agentManager: AgentManager,
        sessionManager: SessionManager,
        themeManager: ThemeManager,
        gitBranchMonitor: GitBranchMonitor
    ) {
        self.agentManager = agentManager
        self.sessionManager = sessionManager
        self.themeManager = themeManager
        self.gitBranchMonitor = gitBranchMonitor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        setupViews()
        agentManager.addObserver(id: "SidebarView") { [weak self] in
            self?.refresh()
        }
        sessionManager.addObserver(id: "SidebarView-sessions") { [weak self] in
            self?.refresh()
        }
        gitBranchMonitor.onChange = { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        agentManager.removeObserver(id: "SidebarView")
        sessionManager.removeObserver(id: "SidebarView-sessions")
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        // Fixed-width container pinned to the leading edge: the outer width
        // constraint can animate to 0 and clip instead of fighting content
        // constraints (masksToBounds is set above).
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        headerLabel = NSTextField(labelWithString: "PANES")
        headerLabel.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(headerLabel)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(scrollView)

        listContentView = NSView()
        listContentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = listContentView

        rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 4
        rowsStack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 10, right: 10)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        listContentView.addSubview(rowsStack)

        footerView = NSView()
        footerView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(footerView)

        footerSeparator = NSView()
        footerSeparator.wantsLayer = true
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(footerSeparator)

        settingsButton = makeIconButton(
            symbolName: "gearshape",
            accessibilityLabel: "Settings",
            action: #selector(settingsClicked)
        )
        footerView.addSubview(settingsButton)

        trailingBorder = NSView()
        trailingBorder.wantsLayer = true
        trailingBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingBorder)

        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentContainer.widthAnchor.constraint(equalToConstant: Self.width),

            headerLabel.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 14),
            headerLabel.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 14),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerView.topAnchor),

            listContentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            listContentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            listContentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            listContentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            listContentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            rowsStack.leadingAnchor.constraint(equalTo: listContentView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: listContentView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: listContentView.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: listContentView.bottomAnchor),

            footerView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            footerView.heightAnchor.constraint(equalToConstant: 36),

            footerSeparator.topAnchor.constraint(equalTo: footerView.topAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: footerView.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: footerView.trailingAnchor),
            footerSeparator.heightAnchor.constraint(equalToConstant: 1),

            settingsButton.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -8),
            settingsButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),

            trailingBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingBorder.topAnchor.constraint(equalTo: topAnchor),
            trailingBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingBorder.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func makeIconButton(
        symbolName: String,
        accessibilityLabel: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(configuration)
        button.imagePosition = .imageOnly
        button.toolTip = accessibilityLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
        return button
    }

    @objc private func settingsClicked() {
        onSettingsRequested?()
    }

    // MARK: - Refresh

    func refreshTheme() {
        refresh()
    }

    private func refresh() {
        let theme = themeManager.currentTheme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        headerLabel.textColor = theme.colors.textMuted
        footerSeparator.layer?.backgroundColor = theme.colors.borderSubtle.cgColor
        trailingBorder.layer?.backgroundColor = theme.colors.borderSubtle.cgColor
        settingsButton.contentTintColor = theme.colors.textMuted

        // Reconcile watchers first so rows read freshly-invalidated caches.
        gitBranchMonitor.setWatchedPaths(watchedCwds())
        rebuildRows(theme: theme)
    }

    private func rebuildRows(theme: AppTheme) {
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for pane in sortedPanes() {
            let row = SidebarPaneRowView(theme: theme)
            row.configure(
                title: pane.activeTab?.title ?? "Pane",
                branch: branchForPane(pane),
                dotColor: paneStatusColor(for: pane, theme: theme),
                tabCount: pane.tabs.count,
                highlighted: pane.id == agentManager.activePaneId,
                onSelect: { [weak self] in
                    self?.agentManager.focusPane(pane.id)
                },
                onClose: { [weak self] in
                    self?.agentManager.closePane(pane.id)
                }
            )
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor, constant: -20).isActive = true
        }
    }

    // MARK: - Branch Resolution

    private func branchForPane(_ pane: PaneState) -> String? {
        guard let tab = pane.activeTab, let cwd = effectiveCwd(for: tab) else { return nil }
        return gitBranchMonitor.branch(for: cwd)
    }

    /// The directory the pane's process actually started in: explicit tab cwd,
    /// else the profile's cwd, else the app process's cwd (ghostty inherits it
    /// when workingDirectory is unset).
    private func effectiveCwd(for tab: PaneTab) -> String? {
        if let cwd = tab.cwd {
            return cwd
        }
        if let agent = tab.agent,
           let profileCwd = DefaultAgents.profile(for: agent.profileId)?.cwd
        {
            return profileCwd
        }
        return FileManager.default.currentDirectoryPath
    }

    private func watchedCwds() -> [String] {
        agentManager.panes.values.compactMap { pane in
            pane.activeTab.flatMap { effectiveCwd(for: $0) }
        }
    }

    // MARK: - Status & Sorting

    private func paneStatusColor(for pane: PaneState, theme: AppTheme) -> NSColor {
        guard let tab = pane.activeTab else { return theme.colors.gray }
        if let agent = tab.agent {
            switch agent.status {
            case .idle:
                return theme.colors.textMuted
            case .starting:
                return theme.colors.yellow
            case .running:
                return theme.colors.success
            case .error:
                return theme.colors.danger
            case .stopped:
                return theme.colors.gray
            }
        }
        switch tab.type {
        case .terminal:
            return theme.colors.accent
        case .agent:
            return theme.colors.textMuted
        }
    }

    private func sortedPanes() -> [PaneState] {
        agentManager.panes.values.sorted { lhs, rhs in
            paneSortKey(lhs.id) < paneSortKey(rhs.id)
        }
    }

    private func paneSortKey(_ paneId: String) -> Int {
        let numberPart = paneId.split(separator: "-").last
        if let numberPart, let number = Int(numberPart) {
            return number
        }
        return Int.max
    }
}

// MARK: - Pane Row

private final class SidebarPaneRowView: NSView {
    private let dotView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private let branchLabel = NSTextField(labelWithString: "")
    private var titleBottomConstraint: NSLayoutConstraint!
    private var branchConstraints: [NSLayoutConstraint] = []
    private var onSelect: (() -> Void)?
    private var onClose: (() -> Void)?
    private let theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup() {
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3
        dotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotView)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        badgeContainer.wantsLayer = true
        badgeContainer.layer?.cornerRadius = 8
        badgeContainer.layer?.backgroundColor = theme.colors.bgRaised.cgColor
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeContainer)

        badgeLabel.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
        badgeLabel.textColor = theme.colors.textMuted
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(badgeLabel)

        closeButton.target = self
        closeButton.action = #selector(handleClose)
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 14, weight: .regular)
        closeButton.contentTintColor = theme.colors.textMuted
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        branchLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        branchLabel.textColor = theme.colors.textMuted
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(branchLabel)

        titleBottomConstraint = titleLabel.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: -7
        )
        branchConstraints = [
            branchLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            branchLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            branchLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            branchLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ]

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dotView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: badgeContainer.leadingAnchor, constant: -6
            ),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            badgeContainer.trailingAnchor.constraint(
                equalTo: closeButton.leadingAnchor, constant: -4
            ),
            badgeContainer.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            badgeContainer.heightAnchor.constraint(equalToConstant: 16),

            badgeLabel.leadingAnchor.constraint(
                equalTo: badgeContainer.leadingAnchor, constant: 5
            ),
            badgeLabel.trailingAnchor.constraint(
                equalTo: badgeContainer.trailingAnchor, constant: -5
            ),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
        ])
    }

    func configure(
        title: String,
        branch: String?,
        dotColor: NSColor,
        tabCount: Int,
        highlighted: Bool,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onClose = onClose
        titleLabel.stringValue = title
        dotView.layer?.backgroundColor = dotColor.cgColor
        badgeContainer.isHidden = tabCount <= 1
        badgeLabel.stringValue = "\(tabCount)"
        closeButton.contentTintColor = highlighted
            ? theme.colors.textPrimary
            : theme.colors.textMuted
        layer?.backgroundColor = highlighted
            ? theme.colors.bgRaised.cgColor
            : NSColor.clear.cgColor

        if let branch {
            branchLabel.stringValue = "⎇ \(branch)"
            branchLabel.isHidden = false
            titleBottomConstraint.isActive = false
            NSLayoutConstraint.activate(branchConstraints)
        } else {
            branchLabel.stringValue = ""
            branchLabel.isHidden = true
            NSLayoutConstraint.deactivate(branchConstraints)
            titleBottomConstraint.isActive = true
        }
    }

    @objc private func handleClose() {
        onClose?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isInteractiveSubview(hitTest(point)) {
            super.mouseDown(with: event)
            return
        }
        onSelect?()
    }

    private func isInteractiveSubview(_ view: NSView?) -> Bool {
        var current = view
        while let candidate = current, candidate !== self {
            if candidate is NSControl {
                return true
            }
            current = candidate.superview
        }
        return false
    }
}
```

- [ ] **Step 3: Update MainContentViewController**

In `Sources/Soprano/App/MainContentViewController.swift`:

3a. Replace the two width constants (lines with `collapsedSidebarWidth` / `expandedSidebarWidth`):

```swift
    private static let sidebarWidth: CGFloat = 220
    private static let sidebarVisibleKey = "soprano-sidebar-visible"
```

3b. Add two stored properties next to the existing manager properties, and extend the initializer:

```swift
    let gitBranchMonitor: GitBranchMonitor
    private var sidebarVisible: Bool
```

```swift
    init(
        agentManager: AgentManager,
        sessionManager: SessionManager,
        themeManager: ThemeManager,
        gitBranchMonitor: GitBranchMonitor,
        onSettingsRequested: (() -> Void)? = nil
    ) {
        self.agentManager = agentManager
        self.sessionManager = sessionManager
        self.themeManager = themeManager
        self.gitBranchMonitor = gitBranchMonitor
        self.onSettingsRequested = onSettingsRequested
        self.sidebarVisible =
            UserDefaults.standard.object(forKey: Self.sidebarVisibleKey) as? Bool ?? true
        super.init(nibName: nil, bundle: nil)
    }
```

3c. In `loadView()`, replace the sidebar construction block (the `SidebarView(...)` init, the `onSettingsRequested` assignment, and the whole `onExpandedChanged` closure) with:

```swift
        sidebarView = SidebarView(
            agentManager: agentManager,
            sessionManager: sessionManager,
            themeManager: themeManager,
            gitBranchMonitor: gitBranchMonitor
        )
        sidebarView.onSettingsRequested = onSettingsRequested
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarView, positioned: .above, relativeTo: splitTreeView)
```

3d. Replace the `sidebarWidthConstraint` creation:

```swift
        sidebarWidthConstraint = sidebarView.widthAnchor.constraint(
            equalToConstant: sidebarVisible ? Self.sidebarWidth : 0
        )
```

3e. Replace `toggleSidebar()`:

```swift
    func toggleSidebar() {
        sidebarVisible.toggle()
        UserDefaults.standard.set(sidebarVisible, forKey: Self.sidebarVisibleKey)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.sidebarWidthConstraint.animator().constant = self.sidebarVisible
                ? Self.sidebarWidth
                : 0
            self.view.layoutSubtreeIfNeeded()
        }
    }
```

- [ ] **Step 4: Thread the monitor through MainWindowController and AppDelegate**

In `Sources/Soprano/App/MainWindowController.swift`, add a stored property after `let themeManager: ThemeManager`:

```swift
    let gitBranchMonitor: GitBranchMonitor
```

Extend the initializer signature and body:

```swift
    init(
        agentManager: AgentManager,
        sessionManager: SessionManager,
        themeManager: ThemeManager,
        gitBranchMonitor: GitBranchMonitor,
        settings: AppSettings
    ) {
        self.agentManager = agentManager
        self.sessionManager = sessionManager
        self.themeManager = themeManager
        self.gitBranchMonitor = gitBranchMonitor
        self.settings = settings
```

And pass it where `MainContentViewController` is created:

```swift
        let contentVC = MainContentViewController(
            agentManager: agentManager,
            sessionManager: sessionManager,
            themeManager: themeManager,
            gitBranchMonitor: gitBranchMonitor,
            onSettingsRequested: { [weak self] in
                self?.openSettings()
            }
        )
```

In `Sources/Soprano/App/AppDelegate.swift`, create the monitor after `let sessionManager = ...` and pass it:

```swift
        let gitBranchMonitor = GitBranchMonitor()
```

```swift
        let controller = MainWindowController(
            agentManager: agentManager,
            sessionManager: sessionManager,
            themeManager: themeManager,
            gitBranchMonitor: gitBranchMonitor,
            settings: settings
        )
```

- [ ] **Step 5: Amend the spec's cwd fallback line**

In `docs/superpowers/specs/2026-07-19-cmux-style-sidebar-design.md`, replace:

```
- `func setWatchedPaths(_ paths: [String])` — the sidebar passes the set of
  effective spawn cwds for current panes (`tab.cwd`, falling back to the
  profile's cwd) after each rebuild; the monitor adds/removes watchers to
  match.
```

with:

```
- `func setWatchedPaths(_ paths: [String])` — the sidebar passes the set of
  effective spawn cwds for current panes (`tab.cwd`, falling back to the
  profile's cwd, then to the app process's cwd — which is what ghostty
  spawns inherit when workingDirectory is unset) after each rebuild; the
  monitor adds/removes watchers to match.
```

- [ ] **Step 6: Build**

```bash
cd /Users/furkanulker/git/private/soprano
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build
```

Expected: `Build complete!` with no warnings about unused properties. If the compiler reports remaining references to `SidebarSection`, `onExpandedChanged`, or the old width constants, those call sites were missed — fix them.

- [ ] **Step 7: Screenshot verification**

Run the Standard verification cycle (label `task2-visible`). Expected in the PNG:
- Left sidebar ~220pt: "PANES" header top-left, one row "Terminal 1" with a colored status dot, gear icon bottom-right above the status bar, hairline right border.
- The row for the active pane has a raised (lighter) background.
- Because the app was launched from the repo directory, the row shows a second line `⎇ main` (the repo's current branch).

Then toggle off, capture, toggle on:

```bash
"$SCRATCH/driver" key "$PID" 14 cmd     # Cmd+E hides
sleep 1
screencapture -x -o -l "$WID" "$SCRATCH/verify-task2-hidden.png"
"$SCRATCH/driver" key "$PID" 14 cmd     # Cmd+E shows again
```

Expected: `verify-task2-hidden.png` shows the terminal flush against the window's left edge (no sidebar).

Relaunch persistence: hide the sidebar (one more Cmd+E), `pkill -x Soprano`, relaunch with the standard cycle, capture `verify-task2-persist.png`. Expected: sidebar still hidden. Then Cmd+E to show it again and `pkill -x Soprano`.

- [ ] **Step 8: Commit**

```bash
git add Sources/Soprano/Views/SidebarView.swift \
    Sources/Soprano/App/MainContentViewController.swift \
    Sources/Soprano/App/MainWindowController.swift \
    Sources/Soprano/App/AppDelegate.swift \
    docs/superpowers/specs/2026-07-19-cmux-style-sidebar-design.md
git commit -m "feat: replace activity-bar sidebar with cmux-style pane list"
```

---

### Task 3: Spawn menu and sessions footer menu

**Files:**
- Modify: `Sources/Soprano/Views/SidebarView.swift`

**Interfaces:**
- Consumes: Task 2's `SidebarView` (`makeIconButton`, `contentContainer`, `headerLabel`, `footerView`, `settingsButton`, `refresh` theme block); `DefaultAgents.all: [AgentProfile]` (`profile.id`, `profile.name`); `AgentManager.spawnAgent(_ profileId: String) -> String` (`@discardableResult`), `spawnTerminal() -> String`; `SessionManager.sessions: [WorkspaceSession]` (`session.id: String`, `session.name`, `session.savedAt`), `loadSession(_ sessionId: String)`, `saveSession(name: String)`.
- Produces: no new external API — sidebar becomes feature-complete for the spec.

- [ ] **Step 1: Add the buttons and their constraints**

In `SidebarView`, add two properties after `private var settingsButton: NSButton!`:

```swift
    private var plusButton: NSButton!
    private var sessionsButton: NSButton!
```

In `setupViews()`, after the `headerLabel` block, add:

```swift
        plusButton = makeIconButton(
            symbolName: "plus",
            accessibilityLabel: "New Pane",
            action: #selector(plusClicked)
        )
        contentContainer.addSubview(plusButton)
```

After the `settingsButton` block, add:

```swift
        sessionsButton = makeIconButton(
            symbolName: "clock.arrow.trianglehead.counterclockwise.rotate.90",
            accessibilityLabel: "Sessions",
            action: #selector(sessionsClicked)
        )
        footerView.addSubview(sessionsButton)
```

In the `NSLayoutConstraint.activate([...])` list, add:

```swift
            plusButton.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -8),
            plusButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),

            sessionsButton.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: 8),
            sessionsButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
```

In `refresh()`, next to the `settingsButton.contentTintColor` line, add:

```swift
        plusButton.contentTintColor = theme.colors.textMuted
        sessionsButton.contentTintColor = theme.colors.textMuted
```

- [ ] **Step 2: Add the menu actions**

Add to `SidebarView` (after `settingsClicked`):

```swift
    // MARK: - Menus

    @objc private func plusClicked() {
        let menu = NSMenu()
        for profile in DefaultAgents.all where profile.id != "terminal" {
            let item = NSMenuItem(
                title: profile.name,
                action: #selector(spawnMenuItemClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.id
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let terminalItem = NSMenuItem(
            title: "Terminal",
            action: #selector(spawnMenuItemClicked(_:)),
            keyEquivalent: ""
        )
        terminalItem.target = self
        terminalItem.representedObject = "terminal"
        menu.addItem(terminalItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: plusButton)
    }

    @objc private func spawnMenuItemClicked(_ sender: NSMenuItem) {
        guard let profileId = sender.representedObject as? String else { return }
        _ = agentManager.spawnAgent(profileId)
    }

    @objc private func sessionsClicked() {
        let menu = NSMenu()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        if sessionManager.sessions.isEmpty {
            menu.addItem(NSMenuItem(title: "No Saved Sessions", action: nil, keyEquivalent: ""))
        }
        for session in sessionManager.sessions {
            let item = NSMenuItem(
                title: "\(session.name) — \(dateFormatter.string(from: session.savedAt))",
                action: #selector(loadSessionItemClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = session.id
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let saveItem = NSMenuItem(
            title: "Save Session As…",
            action: #selector(saveSessionClicked),
            keyEquivalent: ""
        )
        saveItem.target = self
        menu.addItem(saveItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: sessionsButton)
    }

    @objc private func loadSessionItemClicked(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        sessionManager.loadSession(sessionId)
    }

    @objc private func saveSessionClicked() {
        let alert = NSAlert()
        alert.messageText = "Save Session"
        alert.informativeText = "Name this workspace session:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Session name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        sessionManager.saveSession(name: name)
    }
```

Note: `NSMenu.autoenablesItems` (default true) auto-disables the action-less "No Saved Sessions" item — no manual `isEnabled` needed. The menus are native `NSMenu`s and deliberately not custom-themed, same as the app's context menus.

- [ ] **Step 3: Build**

```bash
cd /Users/furkanulker/git/private/soprano
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build
```

Expected: `Build complete!`

- [ ] **Step 4: Interactive verification**

Launch with the standard cycle, then (Soprano must be frontmost for menu keyboard navigation, so skip the focus-restore line this time):

```bash
osascript -e 'tell application "System Events" to tell process "Soprano" to set frontmost to true'
osascript -e 'tell application "System Events" to tell process "Soprano" to click button "New Pane" of window 1'
sleep 1
screencapture -x -o "$SCRATCH/verify-task3-menu.png"   # full screen: popped menus aren't part of the app window
```

Expected in the PNG: a menu below the `+` button listing Codex, Claude Code, OpenCode, a separator, Terminal.

Select "Terminal" via keyboard (menu is open and tracking):

```bash
"$SCRATCH/driver" key "$PID" 125    # down
"$SCRATCH/driver" key "$PID" 125
"$SCRATCH/driver" key "$PID" 125
"$SCRATCH/driver" key "$PID" 125
"$SCRATCH/driver" key "$PID" 36     # return selects Terminal
sleep 1
screencapture -x -o -l "$WID" "$SCRATCH/verify-task3-spawned.png"
```

Expected: a second pane appears in the tiling area and a second row in the sidebar.

Sessions menu:

```bash
osascript -e 'tell application "System Events" to tell process "Soprano" to click button "Sessions" of window 1'
sleep 1
screencapture -x -o "$SCRATCH/verify-task3-sessions.png"
"$SCRATCH/driver" key "$PID" 53     # escape dismisses the menu
```

Expected in the PNG: a menu above/below the clock icon showing either saved sessions or the disabled "No Saved Sessions", plus "Save Session As…". If AX button names don't resolve, fall back to clicking coordinates from the previous screenshots (`osascript ... click at {x, y}`). Kill the app afterwards.

- [ ] **Step 5: Commit**

```bash
git add Sources/Soprano/Views/SidebarView.swift
git commit -m "feat: sidebar spawn menu and sessions footer menu"
```

---

### Task 4: Final verification sweep

**Files:**
- No source changes expected (fix regressions here if found).

**Interfaces:**
- Consumes: everything above; the spec's Verification section (6 checks).

- [ ] **Step 1: Dead-code sweep**

```bash
cd /Users/furkanulker/git/private/soprano
grep -rn "SidebarSection\|SidebarActionRowView\|onExpandedChanged\|collapsedSidebarWidth\|expandedSidebarWidth" Sources
```

Expected: no output. Any hit is leftover dead code — remove it and rebuild.

- [ ] **Step 2: Release build**

```bash
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build -c release
```

Expected: `Build complete!`

- [ ] **Step 3: Branch live-update check**

Create a scratch repo, launch the app from inside it, and change branches:

```bash
SCRATCH=/private/tmp/claude-501/-Users-furkanulker-git-private-soprano/33105055-4294-4ee0-82c5-5eb20ce13c03/scratchpad
REPO="$SCRATCH/live-repo"
rm -rf "$REPO" && mkdir -p "$REPO" && cd "$REPO"
git init -b main && git -c user.email=t@t -c user.name=t commit --allow-empty -m init
pkill -x Soprano; sleep 1
/Users/furkanulker/git/private/soprano/.build/debug/Soprano > /dev/null 2>&1 &
sleep 3
# ... capture verify-task4-main.png with the standard cycle's PID/WID steps ...
git -C "$REPO" checkout -b feature-check
sleep 1
# ... capture verify-task4-feature.png ...
```

Expected: first screenshot's row shows `⎇ main`, second shows `⎇ feature-check` — without relaunching.

- [ ] **Step 4: Worktree check**

```bash
git -C "$REPO" worktree add -b wt-branch "$SCRATCH/live-wt"
pkill -x Soprano; sleep 1
cd "$SCRATCH/live-wt"
/Users/furkanulker/git/private/soprano/.build/debug/Soprano > /dev/null 2>&1 &
sleep 3
# ... capture verify-task4-worktree.png ...
pkill -x Soprano
```

Expected: the row shows `⎇ wt-branch`.

- [ ] **Step 5: Session round-trip**

Launch from the soprano repo, then: frontmost the app, click Sessions → "Save Session As…", type a name, Return:

```bash
osascript -e 'tell application "System Events" to tell process "Soprano" to set frontmost to true'
osascript -e 'tell application "System Events" to tell process "Soprano" to click button "Sessions" of window 1'
sleep 1
"$SCRATCH/driver" key "$PID" 126    # up arrow — "Save Session As…" is the last item
"$SCRATCH/driver" key "$PID" 36     # return opens the alert
sleep 1
osascript -e 'tell application "System Events" to keystroke "smoke-test"'
"$SCRATCH/driver" key "$PID" 36     # return = Save
sleep 1
osascript -e 'tell application "System Events" to tell process "Soprano" to click button "Sessions" of window 1'
sleep 1
screencapture -x -o "$SCRATCH/verify-task4-session.png"
"$SCRATCH/driver" key "$PID" 53
pkill -x Soprano
```

Expected: the sessions menu screenshot lists "smoke-test — <date>".

- [ ] **Step 6: Manual spot-checks for the human partner**

Two checks are left manual (fragile to automate): theme switching (Settings → General → change theme; the sidebar should repaint immediately) and general feel of the ⌘E animation. Report these as "please verify by hand" in the task summary — do not mark them automated-passed.

- [ ] **Step 7: Commit (only if fixes were needed)**

```bash
git add -A && git commit -m "fix: sidebar verification follow-ups"
```

If nothing changed, skip the commit and report the sweep clean.
