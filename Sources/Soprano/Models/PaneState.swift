import Foundation

/// The type of content in a pane tab.
enum PaneType: String, Codable {
    case agent
    case terminal

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        switch rawValue {
        case Self.agent.rawValue:
            self = .agent
        case Self.terminal.rawValue, "browser":
            // Legacy sessions may still contain browser tabs. Restore them as terminals.
            self = .terminal
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown pane type: \(rawValue)"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A single tab within a pane.
struct PaneTab: Identifiable {
    let id: String
    let type: PaneType
    var title: String
    var agent: AgentInstance?
    var cwd: String?
}

/// A pane in the tiling layout, containing one or more tabs.
final class PaneState: Identifiable {
    let id: String
    var tabs: [PaneTab]
    var activeTabIndex: Int

    static let maxTabsPerPane = 10

    init(id: String, tabs: [PaneTab], activeTabIndex: Int = 0) {
        self.id = id
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
    }

    var activeTab: PaneTab? {
        guard !tabs.isEmpty else { return nil }
        let index = min(activeTabIndex, tabs.count - 1)
        return tabs[max(0, index)]
    }

    func clampedActiveIndex() -> Int {
        guard !tabs.isEmpty else { return 0 }
        return min(max(0, activeTabIndex), tabs.count - 1)
    }
}
