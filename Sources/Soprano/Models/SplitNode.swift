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
        var ids = Set<String>()
        insertLeafIds(into: &ids)
        return ids
    }

    /// Adds this tree's leaf pane IDs to `ids`, so callers collecting several
    /// trees fill one set instead of merging one per subtree.
    func insertLeafIds(into ids: inout Set<String>) {
        switch self {
        case .leaf(let id):
            ids.insert(id)
        case .split(let branch):
            branch.first.insertLeafIds(into: &ids)
            branch.second.insertLeafIds(into: &ids)
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

    /// Whether `paneId` is a leaf of this tree, without collecting the
    /// leaves into a set first.
    func containsLeaf(_ paneId: String) -> Bool {
        switch self {
        case .leaf(let id):
            return id == paneId
        case .split(let branch):
            return branch.first.containsLeaf(paneId) || branch.second.containsLeaf(paneId)
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

    /// Find the pane that visually borders the source in a given direction.
    ///
    /// Resolved from pane geometry, not tree shape: in `H[V[a, b], V[c, d]]`,
    /// moving right from `b` lands on `d` beside it, not on `c`, the first leaf
    /// of the neighbouring subtree.
    func adjacentPane(
        from sourceId: String,
        direction: NavigationDirection
    ) -> String? {
        nearestPane(from: sourceId, direction: direction, wrapping: false)
    }

    /// Find the pane at the opposite boundary of the source's row (left/right)
    /// or column (up/down), for navigation wrapping.
    func wrappingPane(
        from sourceId: String,
        direction: NavigationDirection
    ) -> String? {
        nearestPane(from: sourceId, direction: direction, wrapping: true)
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

    /// Pick the pane overlapping the source's row/column that is nearest in
    /// `direction` (or, when wrapping, furthest back from the opposite edge).
    /// Ties go to the pane covering the source's center, then to visual order.
    private func nearestPane(
        from sourceId: String,
        direction: NavigationDirection,
        wrapping: Bool
    ) -> String? {
        let frames = leafFrames(in: PaneFrame(minX: 0, minY: 0, maxX: 1, maxY: 1))
        guard let source = frames.first(where: { $0.id == sourceId })?.frame else { return nil }

        let epsilon = 1e-9
        let sourceSpan = source.span(across: direction)
        let sourceCenter = (sourceSpan.lo + sourceSpan.hi) / 2
        var best: (id: String, distance: Double, centerOffset: Double)?

        for (id, frame) in frames where id != sourceId {
            let span = frame.span(across: direction)
            guard min(span.hi, sourceSpan.hi) - max(span.lo, sourceSpan.lo) > epsilon else { continue }

            let distance: Double
            if wrapping {
                switch direction {
                case .right: distance = frame.minX
                case .left: distance = 1 - frame.maxX
                case .down: distance = frame.minY
                case .up: distance = 1 - frame.maxY
                }
            } else {
                switch direction {
                case .right: distance = frame.minX - source.maxX
                case .left: distance = source.minX - frame.maxX
                case .down: distance = frame.minY - source.maxY
                case .up: distance = source.minY - frame.maxY
                }
                guard distance > -epsilon else { continue }
            }

            let centerOffset = max(0, span.lo - sourceCenter, sourceCenter - span.hi)
            if let current = best {
                let isCloser = distance < current.distance - epsilon
                let isTiedButCentered = abs(distance - current.distance) <= epsilon
                    && centerOffset < current.centerOffset - epsilon
                guard isCloser || isTiedButCentered else { continue }
            }
            best = (id, distance, centerOffset)
        }

        return best?.id
    }

    /// Leaf frames in visual order, laid out inside `frame` by split percentages
    /// (y grows downward, matching first = top for vertical splits).
    private func leafFrames(in frame: PaneFrame) -> [(id: String, frame: PaneFrame)] {
        switch self {
        case .leaf(let id):
            return [(id, frame)]
        case .split(let branch):
            let fraction = branch.splitPercentage / 100
            var first = frame
            var second = frame
            switch branch.direction {
            case .horizontal:
                let x = frame.minX + (frame.maxX - frame.minX) * fraction
                first.maxX = x
                second.minX = x
            case .vertical:
                let y = frame.minY + (frame.maxY - frame.minY) * fraction
                first.maxY = y
                second.minY = y
            }
            return branch.first.leafFrames(in: first) + branch.second.leafFrames(in: second)
        }
    }
}

/// A pane's rectangle in unit layout space (0...1 on both axes).
private struct PaneFrame {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    /// The extent perpendicular to `direction`'s axis.
    func span(across direction: NavigationDirection) -> (lo: Double, hi: Double) {
        direction.isHorizontal ? (minY, maxY) : (minX, maxX)
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
