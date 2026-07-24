import Foundation

/// A single keyboard shortcut binding.
struct KeyBinding: Identifiable, Codable {
    let id: String
    let label: String
    let description: String
    let category: KeyBindingCategory
    let defaultKeys: String
    let mode: KeyBindingMode
    let key: String
    var ctrl: Bool?
    var meta: Bool?
    var shift: Bool?
}

enum KeyBindingCategory: String, Codable {
    case navigation
    case layout
    case agents
    case general
}

enum KeyBindingMode: String, Codable {
    /// Triggered directly (e.g., Cmd+P).
    case direct
    /// Triggered after prefix key (e.g., Ctrl+A → S).
    case prefix
}

/// Full keybinding configuration.
struct KeyBindingConfig: Codable {
    var prefixKey: String
    var prefixTimeoutMs: Int
    var resizeTickPercent: Double
    var bindings: [KeyBinding]
}

enum KeybindingState {
    case normal
    case prefix
    case copy
    case copySelection
}
