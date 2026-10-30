import AppKit
import SopranoAgentsCore
import SwiftTerm

/// Owns every terminal of the window: sessions per thread with a placement (bottom drawer or
/// right-panel tab), their SwiftTerm views and shell processes. Each thread keeps its terminals
/// while the user switches threads; processes end when the shell exits, the thread is deleted or
/// the app quits. Shows no dialogs: callers report a missing workspace.
@MainActor
final class ThreadTerminalStore: NSObject, LocalProcessTerminalViewDelegate {
    typealias Placement = TerminalSessions.Placement

    enum Change: Equatable {
        /// A session of the thread was created, closed, exited or pruned.
        case sessions(threadID: String)
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
            if event == .threadListChanged || event == .projectsChanged { self?.pruneDeletedThreads() }
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

    func sessions(for threadID: String, placement: Placement) -> [TerminalSessionInfo] {
        sessions.sessions(for: threadID, placement: placement)
    }

    func activeSession(for threadID: String, placement: Placement) -> TerminalSessionInfo? {
        sessions.activeSession(for: threadID, placement: placement)
    }

    func session(_ sessionID: String) -> (threadID: String, info: TerminalSessionInfo, placement: Placement)? {
        sessions.locate(sessionID)
    }

    func terminalView(_ sessionID: String) -> LocalProcessTerminalView? {
        terminals[sessionID]
    }

    /// The directory a new terminal starts in: the thread's working directory (a scratch
    /// directory is created on demand); nil when it does not exist.
    func workingDirectory(for threadID: String) -> String? {
        guard let thread = engine.thread(threadID) else { return nil }
        let path = engine.workingDirectory(for: thread)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return path
        }
        if thread.projectID == nil && thread.worktreePath == nil {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        return nil
    }

    /// The thread's working directory when that folder is gone; nil when it exists or the thread is unknown.
    func missingWorkspace(for threadID: String) -> String? {
        guard let thread = engine.thread(threadID), workingDirectory(for: threadID) == nil else { return nil }
        return engine.workingDirectory(for: thread)
    }

    // MARK: - Lifecycle

    /// Starts a terminal for `threadID` in its working directory and makes it the placement's
    /// active one. nil when the thread is unknown or its directory no longer exists (the caller
    /// reports it): a terminal never falls back to another folder.
    @discardableResult
    func create(in threadID: String, placement: Placement) -> TerminalSessionInfo? {
        guard engine.thread(threadID) != nil, let cwd = workingDirectory(for: threadID) else { return nil }
        let session = sessions.add(to: threadID, placement: placement)
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        terminal.processDelegate = self
        terminal.optionAsMetaKey = false
        terminal.font = Typography.mono(Typography.terminalSize)
        style(terminal, palette: PaletteCenter.shared.palette)
        terminals[session.id] = terminal
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        launchShell(terminal, shell, cwd)
        notify(.sessions(threadID: threadID))
        return session
    }

    func select(_ sessionID: String) {
        guard let threadID = sessions.locate(sessionID)?.threadID else { return }
        sessions.select(sessionID, in: threadID)
    }

    /// Ends the session's process and forgets it.
    func close(_ sessionID: String) {
        guard let threadID = sessions.locate(sessionID)?.threadID, sessions.close(sessionID, in: threadID) else { return }
        end(sessionID)
        notify(.sessions(threadID: threadID))
    }

    private func end(_ sessionID: String) {
        guard let terminal = terminals.removeValue(forKey: sessionID) else { return }
        terminal.processDelegate = nil
        let pid = terminal.process?.shellPid ?? 0
        if pid > 0 { kill(pid, SIGHUP) }
        terminal.terminate()
        terminal.removeFromSuperview()
    }

    private func pruneDeletedThreads() {
        let removed = sessions.prune(keeping: Set(engine.threads.map(\.id)))
        for session in removed { end(session.info.id) }
        for threadID in Set(removed.map(\.threadID)) { notify(.sessions(threadID: threadID)) }
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

    /// The shell exited: its session closes.
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let identifier = ObjectIdentifier(source)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let (sessionID, _) = terminals.first(where: { ObjectIdentifier($0.value) == identifier }) else { return }
            close(sessionID)
        }
    }
}
