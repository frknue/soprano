import Foundation

/// A slash command or skill omp offers (`get_available_commands` / `available_commands_update`),
/// as the composer's `/` menu lists it.
public struct ProviderCommand: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case command
        case skill
    }

    /// Display name without "/" ("review", "skill:foo").
    public var name: String
    public var kind: Kind
    public var description: String?
    /// What follows the name ("[soft|remote] [focus]", "<file>"), when the provider says.
    public var argumentHint: String?
    /// Short badge text: "Built-in", "Skill", "Extension", "MCP", "Custom"; nil = none.
    public var source: String?
    /// Exactly what the composer inserts ("/review ", "/skill:foo ").
    public var insertText: String

    public init(name: String, kind: Kind, description: String? = nil, argumentHint: String? = nil, source: String? = nil, insertText: String) {
        self.name = name
        self.kind = kind
        self.description = description
        self.argumentHint = argumentHint
        self.source = source
        self.insertText = insertText
    }

    /// Badge text for a provider's command source: builtin → "Built-in", skill → "Skill",
    /// extension → "Extension", mcp_prompt → "MCP", custom/file → "Custom"; anything else nil.
    public static func badge(forSource source: String?) -> String? {
        switch source {
        case "builtin": "Built-in"
        case "skill": "Skill"
        case "extension": "Extension"
        case "mcp_prompt", "mcp": "MCP"
        case "custom", "file": "Custom"
        default: nil
        }
    }

    /// The menu's order and uniqueness: one entry per `insertText` (first wins), commands
    /// alphabetically by name (case-insensitive), then skills alphabetically.
    public static func normalized(_ commands: [ProviderCommand]) -> [ProviderCommand] {
        var seen = Set<String>()
        let unique = commands.filter { seen.insert($0.insertText).inserted }
        return unique.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .command }
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return order == .orderedSame ? lhs.name < rhs.name : order == .orderedAscending
        }
    }
}
