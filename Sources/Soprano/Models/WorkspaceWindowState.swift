import Foundation

/// One complete tiled workspace on a logical window's z-axis.
///
/// The root layer has no parent. Every inner layer belongs to the pane from
/// which the user entered it, allowing sibling panes to retain independent
/// depth branches in their existing regions.
struct WorkspaceDepthLayer {
    var parentPaneId: String?
    var layout: SplitNode?
    var activePaneId: String
    var isExpanded: Bool
}

/// A logical terminal window containing a root layout and pane-owned depth
/// branches. Expanded branches replace only their owning leaf in the visible
/// layout, leaving sibling regions visible and alive.
final class WorkspaceWindowState: Identifiable {
    let id: String
    var title: String
    var isTitleCustom: Bool
    var isSidebarCollapsed: Bool
    private(set) var depthLayers: [WorkspaceDepthLayer]
    private(set) var activeDepthLayerIndex: Int

    var layout: SplitNode? {
        get { depthLayers[activeDepthLayerIndex].layout }
        set { depthLayers[activeDepthLayerIndex].layout = newValue }
    }

    /// The root split with every expanded pane branch composed into its leaf.
    var visibleLayout: SplitNode? {
        guard let rootIndex = depthLayers.firstIndex(where: {
            $0.parentPaneId == nil
        }), let rootLayout = depthLayers[rootIndex].layout
        else { return nil }
        return expanding(rootLayout, visitedLayerIndices: [rootIndex])
    }

    var rootLayout: SplitNode? {
        depthLayers.first(where: { $0.parentPaneId == nil })?.layout
    }

    var activePaneId: String {
        get { depthLayers[activeDepthLayerIndex].activePaneId }
        set { depthLayers[activeDepthLayerIndex].activePaneId = newValue }
    }

    var activeDepth: Int {
        depth(ofLayerAt: activeDepthLayerIndex)
    }

    init(
        id: String,
        title: String,
        isTitleCustom: Bool = false,
        isSidebarCollapsed: Bool = false,
        layout: SplitNode?,
        activePaneId: String
    ) {
        self.id = id
        self.title = title
        self.isTitleCustom = isTitleCustom
        self.isSidebarCollapsed = isSidebarCollapsed
        self.depthLayers = [
            WorkspaceDepthLayer(
                parentPaneId: nil,
                layout: layout,
                activePaneId: activePaneId,
                isExpanded: true
            )
        ]
        self.activeDepthLayerIndex = 0
    }

    init(
        id: String,
        title: String,
        isTitleCustom: Bool = false,
        isSidebarCollapsed: Bool = false,
        depthLayers: [WorkspaceDepthLayer],
        activeDepthLayerIndex: Int
    ) {
        self.id = id
        self.title = title
        self.isTitleCustom = isTitleCustom
        self.isSidebarCollapsed = isSidebarCollapsed
        self.depthLayers = depthLayers.isEmpty
            ? [
                WorkspaceDepthLayer(
                    parentPaneId: nil,
                    layout: nil,
                    activePaneId: "",
                    isExpanded: true
                )
            ]
            : depthLayers
        self.activeDepthLayerIndex = min(
            max(0, activeDepthLayerIndex),
            self.depthLayers.count - 1
        )
        expandAncestors(ofLayerAt: self.activeDepthLayerIndex)
    }

    var paneIds: Set<String> {
        depthLayers.reduce(into: Set<String>()) { result, layer in
            result.formUnion(layer.layout?.leafIds ?? [])
        }
    }

    var maximumDepth: Int {
        depthLayers.indices.map(depth(ofLayerAt:)).max() ?? 0
    }

    func depth(containingPane paneId: String) -> Int? {
        guard let index = layerIndex(containingPane: paneId) else { return nil }
        return depth(ofLayerAt: index)
    }

    func hasDepthBranch(from paneId: String) -> Bool {
        depthLayers.contains { $0.parentPaneId == paneId }
    }

    @discardableResult
    func activateDepth(containingPane paneId: String) -> Bool {
        guard let index = layerIndex(containingPane: paneId) else { return false }
        let changed = activeDepthLayerIndex != index
        activeDepthLayerIndex = index
        return changed
    }

    /// Makes `paneId` part of the visible layout and activates its owning layer.
    ///
    /// Ancestor branches are expanded on the way in, while the pane's own child
    /// branch is collapsed so it no longer replaces the pane being revealed.
    @discardableResult
    func revealPane(_ paneId: String) -> Bool {
        guard let index = layerIndex(containingPane: paneId) else { return false }
        let previousVisibleLayout = visibleLayout
        activeDepthLayerIndex = index
        expandAncestors(ofLayerAt: index)
        for childIndex in depthLayers.indices
        where depthLayers[childIndex].parentPaneId == paneId {
            depthLayers[childIndex].isExpanded = false
        }
        return visibleLayout != previousVisibleLayout
    }

    /// Enter the private child workspace owned by `paneId`.
    @discardableResult
    func goIn(from paneId: String) -> Bool {
        guard let index = depthLayers.firstIndex(where: {
            $0.parentPaneId == paneId
        }) else { return false }
        depthLayers[index].isExpanded = true
        activeDepthLayerIndex = index
        return true
    }

    /// Return to the workspace containing the pane that owns this layer.
    @discardableResult
    func goOut() -> Bool {
        guard let parentPaneId = depthLayers[activeDepthLayerIndex].parentPaneId,
              let parentIndex = layerIndex(containingPane: parentPaneId)
        else { return false }
        depthLayers[activeDepthLayerIndex].isExpanded = false
        activeDepthLayerIndex = parentIndex
        depthLayers[parentIndex].activePaneId = parentPaneId
        return true
    }

    func appendDepth(
        parentPaneId: String,
        layout: SplitNode?,
        activePaneId: String
    ) {
        depthLayers.append(
            WorkspaceDepthLayer(
                parentPaneId: parentPaneId,
                layout: layout,
                activePaneId: activePaneId,
                isExpanded: true
            )
        )
        activeDepthLayerIndex = depthLayers.count - 1
    }

    /// Removes the active layer and all branches nested below any pane in it,
    /// then returns to its owning pane.
    func removeActiveDepthAndDescendants() -> Set<String> {
        guard let parentPaneId = depthLayers[activeDepthLayerIndex].parentPaneId,
              let parentIndex = layerIndex(containingPane: parentPaneId)
        else { return [] }

        let result = removingLayers(startingWith: [activeDepthLayerIndex])
        depthLayers = result.layers
        activeDepthLayerIndex = layerIndex(containingPane: parentPaneId)
            ?? min(parentIndex, depthLayers.count - 1)
        depthLayers[activeDepthLayerIndex].activePaneId = parentPaneId
        return result.removedPaneIds
    }

    /// Removes the hidden branch owned by a pane without affecting sibling
    /// branches or the layer containing that pane.
    func removeDepthBranches(ownedBy paneId: String) -> Set<String> {
        let branchIndices = Set(depthLayers.indices.filter {
            depthLayers[$0].parentPaneId == paneId
        })
        guard !branchIndices.isEmpty else { return [] }
        let containingPaneIndex = layerIndex(containingPane: paneId) ?? 0
        let result = removingLayers(startingWith: branchIndices)
        depthLayers = result.layers
        activeDepthLayerIndex = layerIndex(containingPane: paneId)
            ?? min(containingPaneIndex, depthLayers.count - 1)
        return result.removedPaneIds
    }

    @discardableResult
    func insertSplit(
        at paneId: String,
        newPaneId: String,
        direction: SplitDirection
    ) -> Bool {
        guard let index = layerIndex(containingPane: paneId),
              let currentLayout = depthLayers[index].layout,
              let updated = currentLayout.insertingSplit(
                at: paneId,
                newId: newPaneId,
                direction: direction
              )
        else { return false }
        depthLayers[index].layout = updated
        depthLayers[index].activePaneId = newPaneId
        activeDepthLayerIndex = index
        return true
    }

    @discardableResult
    func removePaneFromOwningLayout(_ paneId: String) -> Bool {
        guard let index = layerIndex(containingPane: paneId),
              let currentLayout = depthLayers[index].layout
        else { return false }
        depthLayers[index].layout = currentLayout.removing(paneId)
        if depthLayers[index].activePaneId == paneId,
           let firstPaneId = depthLayers[index].layout?.firstLeaf
        {
            depthLayers[index].activePaneId = firstPaneId
        }
        activeDepthLayerIndex = index
        return true
    }

    @discardableResult
    func setSplitPercentage(
        atVisiblePath path: [SplitBranchSide],
        to percentage: Double
    ) -> Bool {
        guard let location = splitLocation(atVisiblePath: path),
              let currentLayout = depthLayers[location.layerIndex].layout
        else { return false }
        let updated = currentLayout.settingSplitPercentage(
            at: location.localPath,
            to: percentage
        )
        guard updated != currentLayout else { return false }
        depthLayers[location.layerIndex].layout = updated
        return true
    }

    @discardableResult
    func adjustSplit(
        atVisiblePath path: [SplitBranchSide],
        delta: Double
    ) -> Bool {
        guard let location = splitLocation(atVisiblePath: path),
              let currentLayout = depthLayers[location.layerIndex].layout
        else { return false }
        let updated = currentLayout.adjustingSplit(
            at: location.localPath,
            delta: delta
        )
        guard updated != currentLayout else { return false }
        depthLayers[location.layerIndex].layout = updated
        return true
    }

    private func removingLayers(
        startingWith initialIndices: Set<Int>
    ) -> (layers: [WorkspaceDepthLayer], removedPaneIds: Set<String>) {
        var removedPaneIds = initialIndices.reduce(into: Set<String>()) { result, index in
            result.formUnion(depthLayers[index].layout?.leafIds ?? [])
        }
        var removedLayerIndices = initialIndices
        var foundDescendant = true
        while foundDescendant {
            foundDescendant = false
            for index in depthLayers.indices where !removedLayerIndices.contains(index) {
                guard let owner = depthLayers[index].parentPaneId,
                      removedPaneIds.contains(owner)
                else { continue }
                removedLayerIndices.insert(index)
                removedPaneIds.formUnion(depthLayers[index].layout?.leafIds ?? [])
                foundDescendant = true
            }
        }

        let remainingLayers = depthLayers.enumerated().compactMap { index, layer in
            removedLayerIndices.contains(index) ? nil : layer
        }
        return (remainingLayers, removedPaneIds)
    }

    private func layerIndex(containingPane paneId: String) -> Int? {
        depthLayers.firstIndex { $0.layout?.leafIds.contains(paneId) == true }
    }

    private func expanding(
        _ node: SplitNode,
        visitedLayerIndices: Set<Int>
    ) -> SplitNode {
        switch node {
        case .leaf(let paneId):
            guard let childIndex = depthLayers.firstIndex(where: {
                $0.parentPaneId == paneId && $0.isExpanded
            }), !visitedLayerIndices.contains(childIndex),
            let childLayout = depthLayers[childIndex].layout
            else { return node }
            return expanding(
                childLayout,
                visitedLayerIndices: visitedLayerIndices.union([childIndex])
            )
        case .split(let branch):
            return .split(SplitNode.SplitBranch(
                direction: branch.direction,
                first: expanding(
                    branch.first,
                    visitedLayerIndices: visitedLayerIndices
                ),
                second: expanding(
                    branch.second,
                    visitedLayerIndices: visitedLayerIndices
                ),
                splitPercentage: branch.splitPercentage
            ))
        }
    }

    private func splitLocation(
        atVisiblePath path: [SplitBranchSide]
    ) -> (layerIndex: Int, localPath: [SplitBranchSide])? {
        guard let rootIndex = depthLayers.firstIndex(where: {
            $0.parentPaneId == nil
        }), let rootLayout = depthLayers[rootIndex].layout
        else { return nil }
        return splitLocation(
            in: rootLayout,
            layerIndex: rootIndex,
            localPath: [],
            remainingVisiblePath: path,
            visitedLayerIndices: [rootIndex]
        )
    }

    private func splitLocation(
        in node: SplitNode,
        layerIndex: Int,
        localPath: [SplitBranchSide],
        remainingVisiblePath: [SplitBranchSide],
        visitedLayerIndices: Set<Int>
    ) -> (layerIndex: Int, localPath: [SplitBranchSide])? {
        switch node {
        case .split(let branch):
            guard let side = remainingVisiblePath.first else {
                return (layerIndex, localPath)
            }
            let child = side == .first ? branch.first : branch.second
            return splitLocation(
                in: child,
                layerIndex: layerIndex,
                localPath: localPath + [side],
                remainingVisiblePath: Array(remainingVisiblePath.dropFirst()),
                visitedLayerIndices: visitedLayerIndices
            )
        case .leaf(let paneId):
            guard let childIndex = depthLayers.firstIndex(where: {
                $0.parentPaneId == paneId && $0.isExpanded
            }), !visitedLayerIndices.contains(childIndex),
            let childLayout = depthLayers[childIndex].layout
            else { return nil }
            return splitLocation(
                in: childLayout,
                layerIndex: childIndex,
                localPath: [],
                remainingVisiblePath: remainingVisiblePath,
                visitedLayerIndices: visitedLayerIndices.union([childIndex])
            )
        }
    }

    private func expandAncestors(ofLayerAt index: Int) {
        var currentIndex = index
        var visited: Set<Int> = []
        while visited.insert(currentIndex).inserted {
            depthLayers[currentIndex].isExpanded = true
            guard let parentPaneId = depthLayers[currentIndex].parentPaneId,
                  let parentIndex = layerIndex(containingPane: parentPaneId)
            else { return }
            currentIndex = parentIndex
        }
    }

    private func depth(ofLayerAt index: Int) -> Int {
        var depth = 0
        var currentIndex = index
        var visited: Set<Int> = []
        while visited.insert(currentIndex).inserted,
              let parentPaneId = depthLayers[currentIndex].parentPaneId,
              let parentIndex = layerIndex(containingPane: parentPaneId)
        {
            depth += 1
            currentIndex = parentIndex
        }
        return depth
    }
}
