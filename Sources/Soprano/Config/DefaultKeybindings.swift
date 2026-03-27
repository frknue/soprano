import Foundation

/// Default keybinding configuration.
enum DefaultKeybindings {
    static let config = KeyBindingConfig(
        prefixKey: "a",
        prefixTimeoutMs: 1500,
        resizeTickPercent: 5,
        bindings: [
            // Navigation (direct: Ctrl+H/J/K/L)
            KeyBinding(id: "nav-left", label: "Focus Left", description: "Move focus to the pane on the left", category: .navigation, defaultKeys: "Ctrl+H", mode: .direct, key: "h", ctrl: true),
            KeyBinding(id: "nav-down", label: "Focus Down", description: "Move focus to the pane below", category: .navigation, defaultKeys: "Ctrl+J", mode: .direct, key: "j", ctrl: true),
            KeyBinding(id: "nav-up", label: "Focus Up", description: "Move focus to the pane above", category: .navigation, defaultKeys: "Ctrl+K", mode: .direct, key: "k", ctrl: true),
            KeyBinding(id: "nav-right", label: "Focus Right", description: "Move focus to the pane on the right", category: .navigation, defaultKeys: "Ctrl+L", mode: .direct, key: "l", ctrl: true),

            // Resize (prefix: Ctrl+A → Shift+H/J/K/L)
            KeyBinding(id: "resize-left", label: "Shrink Left", description: "Shrink the active pane to the left", category: .layout, defaultKeys: "Prefix → H", mode: .prefix, key: "h", shift: true),
            KeyBinding(id: "resize-down", label: "Grow Down", description: "Grow the active pane downward", category: .layout, defaultKeys: "Prefix → J", mode: .prefix, key: "j", shift: true),
            KeyBinding(id: "resize-up", label: "Shrink Up", description: "Shrink the active pane upward", category: .layout, defaultKeys: "Prefix → K", mode: .prefix, key: "k", shift: true),
            KeyBinding(id: "resize-right", label: "Grow Right", description: "Grow the active pane to the right", category: .layout, defaultKeys: "Prefix → L", mode: .prefix, key: "l", shift: true),

            // Layout (prefix)
            KeyBinding(id: "split-horizontal", label: "Split Horizontal", description: "Split the active pane horizontally", category: .layout, defaultKeys: "Prefix → S", mode: .prefix, key: "s"),
            KeyBinding(id: "split-vertical", label: "Split Vertical", description: "Split the active pane vertically", category: .layout, defaultKeys: "Prefix → V", mode: .prefix, key: "v"),
            KeyBinding(id: "close-pane", label: "Close Pane", description: "Close the active pane", category: .layout, defaultKeys: "Prefix → Q", mode: .prefix, key: "q"),
            KeyBinding(id: "kill-pane", label: "Kill Pane", description: "Force-close the active pane", category: .layout, defaultKeys: "Prefix → X", mode: .prefix, key: "x"),
            KeyBinding(id: "maximize-pane", label: "Maximize", description: "Toggle maximize for the active pane", category: .layout, defaultKeys: "Prefix → M", mode: .prefix, key: "m"),

            // Tabs (prefix)
            KeyBinding(id: "new-pane-tab", label: "New Tab", description: "Open a new terminal tab in the active pane", category: .layout, defaultKeys: "Prefix → T", mode: .prefix, key: "t"),
            KeyBinding(id: "next-pane-tab", label: "Next Tab", description: "Switch to the next tab", category: .layout, defaultKeys: "Prefix → N", mode: .prefix, key: "n"),
            KeyBinding(id: "prev-pane-tab", label: "Prev Tab", description: "Switch to the previous tab", category: .layout, defaultKeys: "Prefix → P", mode: .prefix, key: "p"),
            KeyBinding(id: "close-pane-tab", label: "Close Tab", description: "Close the active tab", category: .layout, defaultKeys: "Prefix → W", mode: .prefix, key: "w"),

            // Agents (direct: Cmd+1/2/3)
            KeyBinding(id: "launch-codex", label: "Launch Codex", description: "Launch Codex agent", category: .agents, defaultKeys: "⌘1", mode: .direct, key: "1", meta: true),
            KeyBinding(id: "launch-claude-code", label: "Launch Claude", description: "Launch Claude Code agent", category: .agents, defaultKeys: "⌘2", mode: .direct, key: "2", meta: true),
            KeyBinding(id: "launch-opencode", label: "Launch OpenCode", description: "Launch OpenCode agent", category: .agents, defaultKeys: "⌘3", mode: .direct, key: "3", meta: true),

            // General (direct)
            KeyBinding(id: "command-palette", label: "Commands", description: "Open the command palette", category: .general, defaultKeys: "⌘P", mode: .direct, key: "p", meta: true),
            KeyBinding(id: "open-project", label: "Open Project", description: "Open a project directory", category: .general, defaultKeys: "⇧⌘P", mode: .direct, key: "p", meta: true, shift: true),
            KeyBinding(id: "new-terminal", label: "New Terminal", description: "Open a new terminal pane", category: .general, defaultKeys: "⌘T", mode: .direct, key: "t", meta: true),
            KeyBinding(id: "close-active", label: "Close Pane", description: "Close the active pane", category: .general, defaultKeys: "⌘W", mode: .direct, key: "w", meta: true),
            KeyBinding(id: "save-session", label: "Save Session", description: "Save the current workspace session", category: .general, defaultKeys: "⇧⌘S", mode: .direct, key: "s", meta: true, shift: true),
            KeyBinding(id: "toggle-sidebar", label: "Toggle Sidebar", description: "Show or hide the sidebar", category: .general, defaultKeys: "⌘E", mode: .direct, key: "e", meta: true),
            KeyBinding(id: "open-settings", label: "Settings", description: "Open the settings page", category: .general, defaultKeys: "⌘,", mode: .direct, key: ",", meta: true),
            KeyBinding(id: "zoom-in", label: "Zoom In", description: "Increase font size", category: .general, defaultKeys: "⌘=", mode: .direct, key: "=", meta: true),
            KeyBinding(id: "zoom-out", label: "Zoom Out", description: "Decrease font size", category: .general, defaultKeys: "⌘-", mode: .direct, key: "-", meta: true),
            KeyBinding(id: "zoom-reset", label: "Reset Zoom", description: "Reset font size to default", category: .general, defaultKeys: "⌘0", mode: .direct, key: "0", meta: true),
        ]
    )

    // MARK: - Persistence

    private static let key = "soprano-keybindings"

    static func load() -> KeyBindingConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(KeyBindingConfig.self, from: data)
        else {
            return Self.config
        }

        let savedBindingsById = Dictionary(uniqueKeysWithValues: config.bindings.map { ($0.id, $0) })
        let mergedBindings = Self.config.bindings.compactMap { defaultBinding in
            savedBindingsById[defaultBinding.id] ?? defaultBinding
        }

        return KeyBindingConfig(
            prefixKey: config.prefixKey,
            prefixTimeoutMs: config.prefixTimeoutMs,
            resizeTickPercent: config.resizeTickPercent,
            bindings: mergedBindings
        )
    }

    static func save(_ config: KeyBindingConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
