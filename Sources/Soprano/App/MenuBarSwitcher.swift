import AppKit

/// Soprano's terminal window and the Soprano Agents window each bring their own
/// menu bar; this installs the one that belongs to the key window.
///
/// A panel, popover, overlay or sheet keeps the menu bar of the window it hangs
/// off, so the palette or a dialog never swaps it out from under its owner.
/// Windows that belong to neither (an alert, the About panel) leave it as is.
@MainActor
final class MenuBarSwitcher {
    struct Bar {
        let menu: NSMenu
        var windowsMenu: NSMenu?
        var helpMenu: NSMenu?
    }

    enum Owner: Equatable {
        case soprano
        case agents
    }

    /// The terminal window's menu bar. Its Commands menu is rebuilt in place, so
    /// it must never be read back from `NSApp.mainMenu`.
    let sopranoBar: Bar
    private var agentsBar: Bar?
    private(set) var current: Owner = .soprano
    private let owner: (NSWindow) -> Owner?
    private var observer: NSObjectProtocol?

    /// `owner` names the window a root window belongs to, nil for neither.
    init(soprano: Bar, owner: @escaping (NSWindow) -> Owner?) {
        sopranoBar = soprano
        self.owner = owner
    }

    /// Installs Soprano's bar and follows the key window from here on.
    func start() {
        install(.soprano)
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.windowBecameKey(window)
            }
        }
    }

    /// Replaces the Agents bar (it is rebuilt when its shortcuts change).
    func setAgentsBar(_ bar: Bar) {
        agentsBar = bar
        if current == .agents { install(.agents) }
    }

    func windowBecameKey(_ window: NSWindow) {
        guard let owner = owner(Self.rootWindow(of: window)), owner != current else { return }
        install(owner)
    }

    /// The window `window` hangs off: through child-window and sheet parents.
    static func rootWindow(of window: NSWindow) -> NSWindow {
        var root = window
        while let parent = root.parent ?? root.sheetParent {
            root = parent
        }
        return root
    }

    private func install(_ owner: Owner) {
        let bar: Bar
        switch owner {
        case .soprano:
            bar = sopranoBar
        case .agents:
            guard let agentsBar else { return }
            bar = agentsBar
        }
        current = owner
        NSApp.mainMenu = bar.menu
        NSApp.windowsMenu = bar.windowsMenu
        NSApp.helpMenu = bar.helpMenu
    }
}
