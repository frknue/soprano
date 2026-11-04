import AppKit
import SwiftTerm

/// The right panel's terminal tab body: one `ThreadTerminalStore` session's terminal view filling
/// the controller with 8 pt padding on the terminal background. Hosting moves the live view
/// between superviews; the shell keeps running.
@MainActor
final class TerminalSurfaceViewController: NSViewController, FocusRegionController {
    let store: ThreadTerminalStore
    private(set) var sessionID: String?
    private let host = NSView()

    init(store: ThreadTerminalStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = TerminalSurfaceRootView(frame: NSRect(x: 0, y: 0, width: 480, height: 400))
        view = root
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        store.addObserver(self) { [weak self] _ in
            guard let self else { return }
            // The shown session closed or exited: drop its (removed) view.
            if let sessionID, store.terminalView(sessionID) == nil { show(sessionID: nil) }
        }
        show(sessionID: sessionID)
    }

    /// Hosts `sessionID`'s terminal view (nil or an unknown session shows the empty background).
    func show(sessionID: String?) {
        self.sessionID = sessionID
        guard isViewLoaded else { return }
        let terminal = sessionID.flatMap { store.terminalView($0) }
        for subview in host.subviews where subview !== terminal {
            subview.removeFromSuperview()
        }
        guard let terminal, terminal.superview !== host else { return }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: host.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    func focusTerminal() {
        guard let sessionID, let terminal = store.terminalView(sessionID), terminal.superview === host else { return }
        view.window?.makeFirstResponder(terminal)
    }

    // MARK: - FocusRegionController

    var focusRegion: FocusRegion { .terminal }
    var focusRootView: NSView { view }

    func takeFocus() {
        focusTerminal()
    }
}

/// Terminal tab background (`palette.terminalBackground`).
final class TerminalSurfaceRootView: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.terminalBackground.cgColor
    }
}
