import AppKit

/// Static definition of an AI coding agent profile.
struct AgentProfile: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let icon: String
    let color: String
    let description: String
    let command: String
    let args: [String]
    var env: [String: String]?
    var cwd: String?
    var launchScript: String?
    var autoRestart: Bool?
    var restartDelayMs: Int?
    var patterns: OutputPatterns?

    struct OutputPatterns: Codable, Hashable {
        var ready: [String]?
        var error: [String]?
        var idle: [String]?
        var completion: [String]?
    }

    /// Resolve the NSColor from the hex color string.
    var nsColor: NSColor {
        NSColor.fromHex(color)
    }
}
