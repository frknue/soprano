import AppKit

/// The pages of the settings screen, in navigation order.
enum SettingsPage: String, CaseIterable, Sendable {
    case general
    case providers
    case accounts
    case textGeneration = "text-generation"
    case worktrees
    case notifications
    case keybindings
    case archive
    case about

    var title: String {
        switch self {
        case .general: "General"
        case .providers: "Providers"
        case .accounts: "Accounts"
        case .textGeneration: "Text generation"
        case .worktrees: "Worktrees"
        case .notifications: "Notifications"
        case .keybindings: "Keybindings"
        case .archive: "Archive"
        case .about: "About"
        }
    }

    /// SF Symbol for the navigation and the command palette.
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .providers: "cpu"
        case .accounts: "person.2"
        case .textGeneration: "text.bubble"
        case .worktrees: Icon.gitBranch
        case .notifications: "bell"
        case .keybindings: "keyboard"
        case .archive: "archivebox"
        case .about: "info.circle"
        }
    }

    /// Row titles on the page and extra search terms; the command palette's Settings group
    /// matches them and opens the page.
    var searchRows: [(title: String, terms: String)] {
        switch self {
        case .general:
            [("Theme", "color scheme appearance dark light soprano"), ("Chat width", "wide full width column layout messages composer"),
             ("Follow-up behavior", "queue steer running turn send"), ("Project folders", "projects directories open project git repositories")]
        case .providers:
            [("omp", "provider agent cli version path executable"),
             ("Default model", "new thread reasoning"), ("Permissions", "runtime mode approval full access supervised")]
        case .accounts:
            [("Claude accounts", "account usage limits login sign in omp claude anthropic prefer"),
             ("Codex accounts", "account usage limits login sign in omp codex openai chatgpt prefer")]
        case .textGeneration:
            [("Text generation model", "thread titles commit messages branch names"), ("Generate thread titles", "title")]
        case .worktrees:
            [("Worktree location", "folder directory path"), ("Branch prefix", "worktree branch naming")]
        case .notifications:
            [("Thread notifications", "notification alert completion input approval desktop dock badge"), ("Notification sound", "sound")]
        case .keybindings:
            [("Keyboard shortcuts", "keybindings shortcuts chords prefix record")]
        case .archive:
            [("Archived threads", "restore unarchive delete history")]
        case .about:
            [("Version", "about release"), ("Settings file", "settings.json config")]
        }
    }
}
