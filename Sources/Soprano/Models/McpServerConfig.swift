import Foundation

enum McpTransport: String, Codable {
    case stdio
    case sse
}

enum McpServerStatus: String {
    case stopped
    case starting
    case running
    case error
}

/// Static configuration for an MCP server.
struct McpServerConfig: Identifiable, Codable {
    let id: String
    var name: String
    var icon: String
    var color: String
    var command: String
    var args: [String]
    var env: [String: String]?
    var transport: McpTransport
    var port: UInt16
    var autoStart: Bool
}

/// Runtime state of an MCP server process.
final class McpServerInstance: Identifiable {
    let id: String
    var status: McpServerStatus
    var pid: Int32?
    var url: String?
    var startedAt: Date?
    var error: String?

    init(id: String) {
        self.id = id
        self.status = .stopped
    }

    var sseUrl: String? {
        guard url != nil else { return nil }
        return url
    }
}

/// Combined config + runtime state.
struct McpPoolEntry: Identifiable {
    let config: McpServerConfig
    let instance: McpServerInstance
    var id: String { config.id }
}
