import Foundation

/// One complete tiled workspace on a logical window's z-axis.
///
/// The root layer has no parent. Every inner layer belongs to the pane from
/// which the user entered it, allowing sibling panes to retain independent
/// full-screen depth branches.
struct WorkspaceDepthLayer {
    var parentPaneId: String?
    var layout: SplitNode?
    var activePaneId: String
}

/// A logical terminal window containing a root layout and pane-owned depth
/// branches. Only the active layer is rendered; outer and sibling layers stay
/// alive in the background.
final class WorkspaceWindowState: Identifiable {
    let id: String
    var title: String
    var isTitleCustom: Bool
    private(set) var depthLayers: [WorkspaceDepthLayer]
    private(set) var activeDepthLayerIndex: Int

    var layout: SplitNode? {
        get { depthLayers[activeDepthLayerIndex].layout }
        set { depthLayers[activeDepthLayerIndex].layout = newValue }
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
        layout: SplitNode?,
        activePaneId: String
    ) {
        self.id = id
        self.title = title
        self.isTitleCustom = isTitleCustom
        self.depthLayers = [
            WorkspaceDepthLayer(
                parentPaneId: nil,
                layout: layout,
                activePaneId: activePaneId
            )
        ]
        self.activeDepthLayerIndex = 0
    }

    init(
        id: String,
        title: String,
        isTitleCustom: Bool = false,
        depthLayers: [WorkspaceDepthLayer],
        activeDepthLayerIndex: Int
    ) {
        self.id = id
        self.title = title
        self.isTitleCustom = isTitleCustom
        self.depthLayers = depthLayers.isEmpty
            ? [
                WorkspaceDepthLayer(
                    parentPaneId: nil,
                    layout: nil,
                    activePaneId: ""
                )
            ]
            : depthLayers
        self.activeDepthLayerIndex = min(
            max(0, activeDepthLayerIndex),
            self.depthLayers.count - 1
        )
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

    /// Enter the private child workspace owned by `paneId`.
    @discardableResult
    func goIn(from paneId: String) -> Bool {
        guard let index = depthLayers.firstIndex(where: {
            $0.parentPaneId == paneId
        }) else { return false }
        activeDepthLayerIndex = index
        return true
    }

    /// Return to the workspace containing the pane that owns this layer.
    @discardableResult
    func goOut() -> Bool {
        guard let parentPaneId = depthLayers[activeDepthLayerIndex].parentPaneId,
              let parentIndex = layerIndex(containingPane: parentPaneId)
        else { return false }
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
                activePaneId: activePaneId
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
