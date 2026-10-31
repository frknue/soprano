import AppKit
import SopranoAgentsCore

/// Keyboard focus areas. Single-key bindings fire only while their area has focus, and chords
/// without ⌘/⌃ never fire while a text field is editing. Keybinding `when` clauses
/// (`terminalFocus`, `composerFocus`, `!terminalFocus`) become scopes.
enum FocusRegion: String, CaseIterable, Sendable {
    case sidebar
    case timeline
    case composer
    case terminal
    case rightPanel
    case settings

    /// `!terminalFocus`: everywhere except the terminal drawer (and settings).
    static let outsideTerminal: Set<FocusRegion> = [.sidebar, .timeline, .composer, .rightPanel]
}

/// A view controller that owns a focus area. The router finds the focused area by walking up
/// from the first responder to a view whose controller adopts this.
@MainActor
protocol FocusRegionController: AnyObject {
    var focusRegion: FocusRegion { get }
    /// The view that must contain the first responder for this area to count as focused.
    var focusRootView: NSView { get }
    func takeFocus()
}

enum CommandCategory: String, CaseIterable, Sendable {
    case app = "App"
    case view = "View"
    case thread = "Thread"
    case navigation = "Navigation"
    case composer = "Composer"
    case terminal = "Terminal"
    case diff = "Diff"
    case project = "Project"
}

/// Everything a command needs to know about where it was invoked.
@MainActor
struct CommandContext {
    weak var window: NSWindow?
    var engine: AgentEngine?
    var state: WorkspaceState?
    /// The window's workspace; regions reach each other through it.
    weak var workspace: WorkspaceViewController?
    /// The focused area, nil when focus is elsewhere.
    var focus: FocusRegion?
    /// A text field or text view is the first responder.
    var isTextInput: Bool

    /// The selected thread, when one is selected.
    var thread: AgentThread? { engine?.thread(state?.selectedThreadID) }
}

/// One user-invocable action. Commands are the single source for the palette,
/// key bindings, menus, toolbar buttons and the shortcut sheet.
@MainActor
struct AppCommand {
    /// Stable id; also the key in settings.json `keybindings.bindings`.
    let id: String
    let title: String
    /// One line under the title in the command palette ("Show or hide the thread list").
    let description: String
    let category: CommandCategory
    /// Areas where its keys fire. Empty = everywhere.
    let scopes: Set<FocusRegion>
    /// Default chords in Soprano's KeyChord syntax ("cmd+b", "j", "shift+j", "prefix+p");
    /// the first is the one menus and the palette show.
    let defaultKeys: [String]
    /// SF Symbol for the palette.
    let icon: String
    /// Listed in the command palette (false for pure navigation like j/k).
    let inPalette: Bool
    let isEnabled: @MainActor (CommandContext) -> Bool
    let perform: @MainActor (CommandContext) -> Void

    init(
        id: String,
        title: String,
        description: String,
        category: CommandCategory,
        scopes: Set<FocusRegion> = [],
        defaultKeys: [String] = [],
        icon: String = "command",
        inPalette: Bool = true,
        isEnabled: @escaping @MainActor (CommandContext) -> Bool = { _ in true },
        perform: @escaping @MainActor (CommandContext) -> Void
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.category = category
        self.scopes = scopes
        self.defaultKeys = defaultKeys
        self.icon = icon
        self.inPalette = inPalette
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

extension AppCommand {
    /// Whether the command's shortcut (and menu item) applies with `focus`: global commands
    /// everywhere, scoped ones in their regions. With no region focused, commands available
    /// everywhere outside the terminal still apply.
    func isAvailable(in focus: FocusRegion?) -> Bool {
        if scopes.isEmpty { return true }
        guard let focus else { return scopes.isSuperset(of: FocusRegion.outsideTerminal) }
        return scopes.contains(focus)
    }
}

@MainActor
final class CommandRegistry {
    static let shared = CommandRegistry()

    private(set) var commands: [AppCommand] = []
    private var indexByID: [String: Int] = [:]

    func register(_ newCommands: [AppCommand]) {
        for command in newCommands {
            precondition(indexByID[command.id] == nil, "Duplicate command id \(command.id)")
            indexByID[command.id] = commands.count
            commands.append(command)
        }
    }

    func command(_ id: String) -> AppCommand? {
        indexByID[id].map { commands[$0] }
    }

    /// Runs the command when it exists and is enabled. Returns whether it ran.
    @discardableResult
    func perform(_ id: String, in context: CommandContext) -> Bool {
        guard let command = command(id), command.isEnabled(context) else { return false }
        command.perform(context)
        return true
    }
}

/// Registers every module's commands once at launch. Each module owns its
/// `…Commands` enum; this file only lists them.
@MainActor
enum AllCommands {
    static func registerAll(in registry: CommandRegistry = .shared) {
        registry.register(ShellCommands.all)
        registry.register(SidebarCommands.all)
        registry.register(TimelineCommands.all)
        registry.register(ComposerCommands.all)
        registry.register(PanelCommands.all)
        registry.register(AccountCommands.all)
        registry.register(StatisticsCommands.all)
    }
}
