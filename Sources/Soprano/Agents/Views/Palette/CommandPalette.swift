import AppKit
import SopranoAgentsCore

/// The command palette (⌘K, ⌘P) and Open Project… (⇧⌘K) on Soprano's own
/// `CommandPalettePanel` (vendored): one per main window, centered under the titlebar over a
/// scrim, ↑↓ move, ↩ runs, Esc or a click outside closes. The chosen row runs after the panel
/// closed, so the main window has the keyboard again.
@MainActor
final class CommandPalette {
    enum Mode: Equatable {
        case commands
        case projects
    }

    private(set) lazy var panel = CommandPalettePanel(themeManager: ThemeCenter.shared.manager)
    private(set) var mode: Mode?
    private weak var controller: AgentsWindowController?

    init(controller: AgentsWindowController) {
        self.controller = controller
    }

    var isShown: Bool { panel.isVisible && mode != nil }

    /// `palette.open`: shows the commands, or closes the palette when it is open.
    static func toggle(in context: CommandContext) {
        guard let palette = palette(for: context) else { return }
        if palette.isShown {
            palette.dismiss()
        } else {
            palette.show(.commands, context: context)
        }
    }

    /// `project.open`: shows the projects (from the command list too), or closes them.
    static func openProjects(in context: CommandContext) {
        guard let palette = palette(for: context) else { return }
        if palette.isShown, palette.mode == .projects {
            palette.dismiss()
        } else {
            palette.show(.projects, context: context)
        }
    }

    private static func palette(for context: CommandContext) -> CommandPalette? {
        (context.window?.windowController as? AgentsWindowController)?.palette
    }

    func dismiss() {
        mode = nil
        panel.dismiss()
    }

    private func show(_ mode: Mode, context: CommandContext) {
        guard let controller, let window = controller.window else { return }
        let settings = SettingsCenter.shared
        let rows: [PaletteRow]
        let placeholder: String
        let opener: String
        switch mode {
        case .commands:
            rows = PaletteItems.root(
                commands: CommandRegistry.shared.commands,
                context: context,
                keycaps: { settings.keycaps(for: $0) },
                engine: controller.engine,
                now: controller.engine.environment.now()
            )
            placeholder = "Search commands, threads, projects and settings…"
            opener = "palette.open"
        case .projects:
            rows = PaletteItems.projects(
                engine: controller.engine,
                folders: ProjectFolders.scan(settings.settings.projectDirectories)
            )
            placeholder = "Search projects and folders…"
            opener = "project.open"
        }
        self.mode = mode
        panel.show(
            relativeTo: window,
            commands: rows.map(item),
            placeholder: placeholder,
            searchShortcut: settings.keycaps(for: opener) ?? []
        )
    }

    private func item(_ row: PaletteRow) -> CommandItem {
        CommandItem(
            id: row.id,
            icon: row.icon,
            label: row.label,
            description: row.description,
            shortcut: row.shortcut,
            searchText: row.searchText
        ) { [weak self] in
            self?.mode = nil
            // The panel closes right after this returns; run once the main window is key.
            DispatchQueue.main.async { self?.run(row.choice) }
        }
    }

    /// Does what the chosen row says (the panel is already closed).
    func run(_ choice: PaletteChoice) {
        guard let controller else { return }
        switch choice {
        case let .command(id):
            controller.perform(id)
        case let .thread(id):
            controller.state.select(.thread(id))
        case let .project(id):
            startThread(inProject: id)
        case let .folder(path):
            startThread(inProject: controller.engine.addProject(path: path).id)
        case .chooseFolder:
            controller.workspace.sidebar.addProject()
        case let .settings(page):
            guard let window = controller.window else { return }
            SettingsController.present(page: page, engine: controller.engine, over: window)
        }
    }

    private func startThread(inProject id: String) {
        guard let controller else { return }
        ThreadActions.newDraft(projectID: id, state: controller.state)
        controller.perform("composer.focus")
    }
}
