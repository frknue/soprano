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
    /// The terminal immediately outside this one on the pane's z-axis.
    /// `nil` marks a regular, top-level tab.
    var depthParentId: String? = nil
}

/// A pane in the tiling layout, containing one or more logical tabs.
///
/// Depth layers share the same storage as tabs so every terminal surface keeps
/// its existing lifecycle and cache behavior. A layer with `depthParentId` is
/// hidden from the tab strip and is reached by moving inward from its parent.
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

    var rootTabs: [PaneTab] {
        tabs.filter { $0.depthParentId == nil }
    }

    var activeDepthPath: [PaneTab] {
        guard let activeTab else { return [] }

        var path: [PaneTab] = []
        var current: PaneTab? = activeTab
        var visited: Set<String> = []
        while let tab = current, visited.insert(tab.id).inserted {
            path.append(tab)
            current = tab.depthParentId.flatMap { parentId in
                tabs.first { $0.id == parentId }
            }
        }
        return path.reversed()
    }

    var activeDepth: Int {
        max(0, activeDepthPath.count - 1)
    }

    /// The complete linear z-axis branch for the active logical tab, including
    /// inner layers that are currently hidden because the user moved outward.
    var activeDepthBranch: [PaneTab] {
        guard let root = activeDepthPath.first else { return [] }

        var branch = [root]
        var currentId = root.id
        var visited: Set<String> = [root.id]
        while let child = tabs.first(where: { $0.depthParentId == currentId }),
              visited.insert(child.id).inserted
        {
            branch.append(child)
            currentId = child.id
        }
        return branch
    }

    var canGoOut: Bool {
        activeTab?.depthParentId != nil
    }

    var childOfActiveTab: PaneTab? {
        guard let activeTab else { return nil }
        return tabs.first { $0.depthParentId == activeTab.id }
    }

    func descendantIds(of tabId: String) -> Set<String> {
        var descendants: Set<String> = [tabId]
        var addedChild = true
        while addedChild {
            addedChild = false
            for tab in tabs where tab.depthParentId.map(descendants.contains) == true {
                if descendants.insert(tab.id).inserted {
                    addedChild = true
                }
            }
        }
        return descendants
    }

    func clampedActiveIndex() -> Int {
        guard !tabs.isEmpty else { return 0 }
        return min(max(0, activeTabIndex), tabs.count - 1)
    }
}
