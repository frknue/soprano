import AppKit
import SopranoAgentsCore
import SwiftTerm

/// Owns every terminal of the window: sessions per workspace (`WorkspaceRef.key`: a thread or a
/// project draft) with a placement (bottom drawer or right-panel tab), their SwiftTerm views and
/// shell processes. Each workspace keeps its terminals while the user switches; processes end
/// when the shell exits, the thread or project is deleted or the app quits. Shows no dialogs:
/// callers report a missing workspace.
@MainActor
final class ThreadTerminalStore: NSObject, LocalProcessTerminalViewDelegate {
    typealias Placement = TerminalSessions.Placement

    enum Change: Equatable {
        /// A session of the workspace `key` was created, closed, exited or pruned.
        case sessions(key: String)
        /// Every session of the workspace `from` (a project draft) moved to `to` (its thread).
        case moved(from: String, to: String)
    }

    let engine: AgentEngine
    private(set) var sessions = TerminalSessions()
    private var terminals: [String: LocalProcessTerminalView] = [:]
    private var observers: [(owner: () -> AnyObject?, handler: @MainActor (Change) -> Void)] = []

    /// Starts the shell in a new terminal view (`executable`, `cwd`). Tests replace it to record
    /// launches instead of spawning shells.
    var launchShell: (LocalProcessTerminalView, _ executable: String, _ cwd: String) -> Void = { terminal, shell, cwd in
        terminal.startProcess(
            executable: shell,
            args: ["-l"],
            environment: ThreadTerminalStore.environment(),
            execName: "-" + URL(fileURLWithPath: shell).lastPathComponent,
            currentDirectory: cwd
        )
    }

    init(engine: AgentEngine) {
        self.engine = engine
        super.init()
        engine.addObserver(self) { [weak self] event in
            if event == .threadListChanged || event == .projectsChanged { self?.pruneDeletedWorkspaces() }
        }
        PaletteCenter.shared.addObserver(self) { [weak self] palette in self?.applyPalette(palette) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillTerminate), name: NSApplication.willTerminateNotification, object: nil
        )
    }

    // MARK: - Observers

    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (Change) -> Void) {
        observers.append(({ [weak owner] in owner }, handler))
    }

    private func notify(_ change: Change) {
        observers.removeAll { $0.owner() == nil }
        for observer in observers { observer.handler(change) }
    }

    // MARK: - Queries

    func sessions(for key: String, placement: Placement) -> [TerminalSessionInfo] {
        sessions.sessions(for: key, placement: placement)
    }

    func activeSession(for key: String, placement: Placement) -> TerminalSessionInfo? {
        sessions.activeSession(for: key, placement: placement)
    }

    /// The session and the `WorkspaceRef.key` it belongs to.
    func session(_ sessionID: String) -> (key: String, info: TerminalSessionInfo, placement: Placement)? {
        sessions.locate(sessionID)
    }

    func terminalView(_ sessionID: String) -> LocalProcessTerminalView? {
        terminals[sessionID]
    }

    /// The directory a new terminal starts in: the workspace's working directory (a scratch
    /// thread's directory is created on demand); nil when it does not exist.
    func workingDirectory(for workspace: WorkspaceRef) -> String? {
        guard let path = engine.workingDirectory(of: workspace) else { return nil }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return path
        }
        if case let .thread(id) = workspace, let thread = engine.thread(id), thread.projectID == nil, thread.worktreePath == nil {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        return nil
    }

    /// The workspace's working directory when that folder is gone; nil when it exists or the
    /// workspace is unknown.
    func missingWorkspace(for workspace: WorkspaceRef) -> String? {
        guard workingDirectory(for: workspace) == nil else { return nil }
        return engine.workingDirectory(of: workspace)
    }

    // MARK: - Lifecycle

    /// Starts a terminal for `workspace` in its working directory and makes it the placement's
    /// active one. nil when the workspace is unknown or its directory no longer exists (the
    /// caller reports it): a terminal never falls back to another folder.
    @discardableResult
    func create(in workspace: WorkspaceRef, placement: Placement) -> TerminalSessionInfo? {
        guard let cwd = workingDirectory(for: workspace) else { return nil }
        let key = workspace.key
        let session = sessions.add(to: key, placement: placement)
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        terminal.processDelegate = self
        terminal.optionAsMetaKey = false
        terminal.font = Typography.terminal()
        style(terminal, palette: PaletteCenter.shared.palette)
        terminals[session.id] = terminal
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        launchShell(terminal, shell, cwd)
        notify(.sessions(key: key))
        return session
    }

    func select(_ sessionID: String) {
        guard let key = sessions.locate(sessionID)?.key else { return }
        sessions.select(sessionID, in: key)
    }

    /// Ends the session's process and forgets it.
    func close(_ sessionID: String) {
        close(sessionID, reaped: false)
    }

    /// `reaped`: the shell already exited and SwiftTerm waited for it, so its pid is no longer
    /// ours to signal.
    private func close(_ sessionID: String, reaped: Bool) {
        guard let key = sessions.locate(sessionID)?.key, sessions.close(sessionID, in: key) else { return }
        end(sessionID, reaped: reaped)
        notify(.sessions(key: key))
    }

    /// A project draft became thread `threadID` in the same folder: its terminals (shells keep
    /// running) move to the thread.
    func moveDraftSessions(projectID: String, to threadID: String) {
        let draftKey = WorkspaceRef.draft(projectID: projectID).key
        guard sessions.move(from: draftKey, to: threadID) else { return }
        notify(.moved(from: draftKey, to: threadID))
    }

    private func end(_ sessionID: String, reaped: Bool = false) {
        guard let terminal = terminals.removeValue(forKey: sessionID) else { return }
        terminal.processDelegate = nil
        if !reaped {
            let process = terminal.process
            let pid = process?.shellPid ?? 0
            if pid > 0, process?.running == true { kill(pid, SIGHUP) }
            terminal.terminate()
            if pid > 0 { Self.reap(pid) }
        }
        terminal.removeFromSuperview()
    }

    /// Waits for the ended shell so it does not stay a zombie: SwiftTerm's `terminate()` cancels
    /// its exit monitor, the only `waitpid` it makes.
    private nonisolated static func reap(_ pid: pid_t) {
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        exit.setEventHandler {
            // The process has exited, so a blocking wait returns at once; it never depends on
            // the exit being waitable the instant the event arrives.
            while waitpid(pid, nil, 0) == -1, errno == EINTR {}
            exit.cancel()
        }
        exit.resume()
        // Exited before the source was armed: reap it now.
        if waitpid(pid, nil, WNOHANG) != 0 { exit.cancel() }
    }

    private func pruneDeletedWorkspaces() {
        let removed = sessions.prune(keeping: engine.workspaceKeys)
        for session in removed { end(session.info.id) }
        for key in Set(removed.map(\.key)) { notify(.sessions(key: key)) }
    }

    @objc private func applicationWillTerminate() {
        for session in sessions.removeAll() { end(session.id) }
    }

    /// The app's environment for the shell, with terminal capabilities set.
    static func environment() -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Soprano Agents"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        return environment.map { "\($0.key)=\($0.value)" }
    }

    // MARK: - Palette

    private func applyPalette(_ palette: Palette) {
        for terminal in terminals.values { style(terminal, palette: palette) }
    }

    private func style(_ terminal: LocalProcessTerminalView, palette: Palette) {
        terminal.nativeBackgroundColor = palette.terminalBackground
        terminal.nativeForegroundColor = palette.terminalForeground
        terminal.caretColor = palette.terminalCursor
        terminal.selectedTextBackgroundColor = palette.terminalSelection
        terminal.installColors(palette.terminalANSI.map(Self.terminalColor))
    }

    /// SwiftTerm's 16-bit-per-channel color for an sRGB `NSColor`.
    private static func terminalColor(_ color: NSColor) -> SwiftTerm.Color {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func channel(_ value: CGFloat) -> UInt16 { UInt16((max(0, min(1, value)) * 65535).rounded()) }
        return SwiftTerm.Color(red: channel(srgb.redComponent), green: channel(srgb.greenComponent), blue: channel(srgb.blueComponent))
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// The shell exited: its session closes. SwiftTerm reaped it right before this call on the
    /// main queue; closing in the same call leaves no window in which a user's close would
    /// signal the reaped pid.
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let identifier = ObjectIdentifier(source)
        if Thread.isMainThread {
            MainActor.assumeIsolated { shellExited(identifier) }
        } else {
            Task { @MainActor [weak self] in self?.shellExited(identifier) }
        }
    }

    private func shellExited(_ identifier: ObjectIdentifier) {
        guard let (sessionID, _) = terminals.first(where: { ObjectIdentifier($0.value) == identifier }) else { return }
        close(sessionID, reaped: true)
    }
}
