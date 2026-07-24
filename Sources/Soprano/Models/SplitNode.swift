import Foundation

/// Binary tree node representing the tiling layout.
/// Mirrors react-mosaic-component's MosaicNode structure.
indirect enum SplitNode: Codable, Equatable {
    /// A leaf pane identified by its pane ID.
    case leaf(String)

    /// A split containing two children.
    case split(SplitBranch)

    struct SplitBranch: Codable, Equatable {
        var direction: SplitDirection
        var first: SplitNode
        var second: SplitNode
        var splitPercentage: Double

        init(
            direction: SplitDirection,
            first: SplitNode,
            second: SplitNode,
            splitPercentage: Double = 50.0
        ) {
            self.direction = direction
            self.first = first
            self.second = second
            self.splitPercentage = Self.clampedPercentage(splitPercentage)
        }

        fileprivate static func clampedPercentage(_ percentage: Double) -> Double {
            max(10, min(90, percentage))
        }

        private enum CodingKeys: String, CodingKey {
            case direction, first, second, splitPercentage
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                direction: try container.decode(SplitDirection.self, forKey: .direction),
                first: try container.decode(SplitNode.self, forKey: .first),
                second: try container.decode(SplitNode.self, forKey: .second),
                splitPercentage: try container.decode(Double.self, forKey: .splitPercentage)
            )
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(direction, forKey: .direction)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
            try container.encode(splitPercentage, forKey: .splitPercentage)
        }
    }

    // MARK: - Queries

    /// Collect all leaf pane IDs in the tree.
    var leafIds: Set<String> {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(let branch):
            return branch.first.leafIds.union(branch.second.leafIds)
        }
    }

    /// Collect leaf pane IDs in visual tree order (left/top before right/bottom).
    var orderedLeafIds: [String] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(let branch):
            return branch.first.orderedLeafIds + branch.second.orderedLeafIds
        }
    }

    /// Find the first (leftmost/topmost) leaf in the tree.
    var firstLeaf: String? {
        switch self {
        case .leaf(let id):
            return id
        case .split(let branch):
            return branch.first.firstLeaf
        }
    }

    /// Find the path to a specific pane ID.
    func pathTo(_ paneId: String) -> [SplitBranchSide]? {
        switch self {
        case .leaf(let id):
            return id == paneId ? [] : nil
        case .split(let branch):
            if let path = branch.first.pathTo(paneId) {
                return [.first] + path
            }
            if let path = branch.second.pathTo(paneId) {
                return [.second] + path
            }
            return nil
        }
    }

    // MARK: - Mutations

    /// Insert a split at the target pane, placing the new pane as the second child.
    func insertingSplit(
        at targetId: String,
        newId: String,
        direction: SplitDirection
    ) -> SplitNode? {
        switch self {
        case .leaf(let id):
            guard id == targetId else { return nil }
            return .split(SplitBranch(
                direction: direction,
                first: .leaf(id),
                second: .leaf(newId)
            ))
        case .split(let branch):
            if let updatedFirst = branch.first.insertingSplit(
                at: targetId, newId: newId, direction: direction
            ) {
                var newBranch = branch
                newBranch.first = updatedFirst
                return .split(newBranch)
            }
            if let updatedSecond = branch.second.insertingSplit(
                at: targetId, newId: newId, direction: direction
            ) {
                var newBranch = branch
                newBranch.second = updatedSecond
                return .split(newBranch)
            }
            return nil
        }
    }

    /// Remove a pane from the tree, collapsing the parent split.
    func removing(_ targetId: String) -> SplitNode? {
        switch self {
        case .leaf(let id):
            return id == targetId ? nil : self
        case .split(let branch):
            let first = branch.first.removing(targetId)
            let second = branch.second.removing(targetId)
            switch (first, second) {
            case (nil, nil): return nil
            case (nil, let node): return node
            case (let node, nil): return node
            default:
                var newBranch = branch
                newBranch.first = first!
                newBranch.second = second!
                return .split(newBranch)
            }
        }
    }

    /// Find the adjacent pane in a given direction.
    func adjacentPane(
        from sourceId: String,
        direction: NavigationDirection
    ) -> String? {
        guard let sourcePath = pathTo(sourceId) else { return nil }

        let axisDirection: SplitDirection = direction.isHorizontal ? .horizontal : .vertical
        let seekFirst = direction == .left || direction == .up

        // Walk up the path to find an ancestor split with the matching axis
        for i in stride(from: sourcePath.count - 1, through: 0, by: -1) {
            let ancestorPath = Array(sourcePath.prefix(i))
            guard let ancestor = nodeAt(ancestorPath),
                  case .split(let branch) = ancestor,
                  branch.direction == axisDirection
            else { continue }

            let side = sourcePath[i]
            if seekFirst && side == .second {
                return branch.first.boundaryLeaf(seeking: direction)
            }
            if !seekFirst && side == .first {
                return branch.second.boundaryLeaf(seeking: direction)
            }
        }

        return nil
    }

    /// Find the pane at the opposite directional boundary for navigation wrapping.
    func wrappingPane(
        from sourceId: String,
        direction: NavigationDirection
    ) -> String? {
        guard pathTo(sourceId) != nil, leafIds.count > 1 else { return nil }
        return boundaryLeaf(seeking: direction)
    }

    /// Set the split percentage at a path, clamped to the supported bounds.
    func settingSplitPercentage(at path: [SplitBranchSide], to percentage: Double) -> SplitNode {
        guard case .split(var branch) = self else { return self }

        guard let side = path.first else {
            branch.splitPercentage = SplitBranch.clampedPercentage(percentage)
            return .split(branch)
        }

        let remaining = Array(path.dropFirst())
        switch side {
        case .first:
            branch.first = branch.first.settingSplitPercentage(at: remaining, to: percentage)
        case .second:
            branch.second = branch.second.settingSplitPercentage(at: remaining, to: percentage)
        }
        return .split(branch)
    }

    /// Adjust the split percentage at a path.
    func adjustingSplit(at path: [SplitBranchSide], delta: Double) -> SplitNode {
        guard !path.isEmpty else {
            guard case .split(var branch) = self else { return self }
            branch.splitPercentage = SplitBranch.clampedPercentage(branch.splitPercentage + delta)
            return .split(branch)
        }

        guard case .split(var branch) = self else { return self }
        let side = path[0]
        let remaining = Array(path.dropFirst())
        switch side {
        case .first:
            branch.first = branch.first.adjustingSplit(at: remaining, delta: delta)
        case .second:
            branch.second = branch.second.adjustingSplit(at: remaining, delta: delta)
        }
        return .split(branch)
    }

    // MARK: - Private Helpers

    private func nodeAt(_ path: [SplitBranchSide]) -> SplitNode? {
        var current = self
        for side in path {
            guard case .split(let branch) = current else { return nil }
            current = side == .first ? branch.first : branch.second
        }
        return current
    }

    private func boundaryLeaf(seeking direction: NavigationDirection) -> String? {
        switch self {
        case .leaf(let id):
            return id
        case .split(let branch):
            let goFirst = direction == .left || direction == .up
            return goFirst
                ? branch.second.boundaryLeaf(seeking: direction)
                : branch.first.boundaryLeaf(seeking: direction)
        }
    }
}

// MARK: - Supporting Types

enum SplitDirection: String, Codable {
    /// Side by side (left | right)
    case horizontal
    /// Stacked (top / bottom)
    case vertical
}

enum SplitBranchSide: Codable {
    case first
    case second
}

enum NavigationDirection: String {
    case left, right, up, down

    var isHorizontal: Bool {
        self == .left || self == .right
    }
}
