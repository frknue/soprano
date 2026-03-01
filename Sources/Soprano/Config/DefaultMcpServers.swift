import Foundation

/// Default MCP server configuration and persistence.
enum DefaultMcpServers {
    static let defaultConfigs: [McpServerConfig] = []

    private static let key = "soprano-mcp-servers"

    static func load() -> [McpServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let configs = try? JSONDecoder().decode([McpServerConfig].self, from: data)
        else {
            return defaultConfigs
        }
        return configs
    }

    static func save(_ configs: [McpServerConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
