//! The tiling layout of one layout tab (`Models/SplitNode.swift`): a binary tree whose leaves
//! are pane ids, mirroring react-mosaic-component's `MosaicNode`.
//!
//! Persisted with the shape Swift's synthesized `Codable` wrote, so saved workspaces keep
//! opening: `{"leaf":{"_0":"pane-1"}}` and
//! `{"split":{"_0":{"direction":"horizontal","first":…,"second":…,"splitPercentage":50}}}`.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use soprano_types::{NavigationDirection, SplitDirection};

/// Smallest and largest share the first child of a split may take, in percent.
const MIN_PERCENTAGE: f64 = 10.0;
const MAX_PERCENTAGE: f64 = 90.0;

fn clamped_percentage(percentage: f64) -> f64 {
    if percentage.is_nan() { 50.0 } else { percentage.clamp(MIN_PERCENTAGE, MAX_PERCENTAGE) }
}

/// Binary tree node representing the tiling layout.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "NodeRepr", into = "NodeRepr")]
pub enum SplitNode {
    /// A leaf pane identified by its pane id.
    Leaf(String),
    /// A split containing two children.
    Split(Box<SplitBranch>),
}

/// The two children of a split and how the space divides between them.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "BranchRepr")]
#[serde(rename_all = "camelCase")]
pub struct SplitBranch {
    pub direction: SplitDirection,
    pub first: SplitNode,
    pub second: SplitNode,
    /// The first child's share in percent, always within 10…90.
    pub split_percentage: f64,
}

impl SplitBranch {
    /// A branch with `split_percentage` clamped to the supported 10…90 range.
    pub fn new(
        direction: SplitDirection,
        first: SplitNode,
        second: SplitNode,
        split_percentage: f64,
    ) -> Self {
        Self { direction, first, second, split_percentage: clamped_percentage(split_percentage) }
    }

    /// An even 50/50 split.
    pub fn even(direction: SplitDirection, first: SplitNode, second: SplitNode) -> Self {
        Self::new(direction, first, second, 50.0)
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum NodeRepr {
    Leaf {
        #[serde(rename = "_0")]
        id: String,
    },
    Split {
        #[serde(rename = "_0")]
        branch: Box<SplitBranch>,
    },
}

impl From<NodeRepr> for SplitNode {
    fn from(repr: NodeRepr) -> Self {
        match repr {
            NodeRepr::Leaf { id } => SplitNode::Leaf(id),
            NodeRepr::Split { branch } => SplitNode::Split(branch),
        }
    }
}

impl From<SplitNode> for NodeRepr {
    fn from(node: SplitNode) -> Self {
        match node {
            SplitNode::Leaf(id) => NodeRepr::Leaf { id },
            SplitNode::Split(branch) => NodeRepr::Split { branch },
        }
    }
}

/// Decoding clamps the percentage exactly like the initializer does.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BranchRepr {
    direction: SplitDirection,
    first: SplitNode,
    second: SplitNode,
    split_percentage: f64,
}

impl From<BranchRepr> for SplitBranch {
    fn from(repr: BranchRepr) -> Self {
        SplitBranch::new(repr.direction, repr.first, repr.second, repr.split_percentage)
    }
}

/// One step of a path from the root of a layout to one of its nodes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SplitBranchSide {
    First,
    Second,
}

/// A pane's rectangle in unit layout space (0…1 on both axes, y growing downward).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PaneFrame {
    pub min_x: f64,
    pub min_y: f64,
    pub max_x: f64,
    pub max_y: f64,
}

impl PaneFrame {
    /// The whole layout.
    pub const UNIT: PaneFrame = PaneFrame { min_x: 0.0, min_y: 0.0, max_x: 1.0, max_y: 1.0 };

    /// The extent perpendicular to `direction`'s axis.
    pub fn span_across(&self, direction: NavigationDirection) -> (f64, f64) {
        if direction.is_horizontal() { (self.min_y, self.max_y) } else { (self.min_x, self.max_x) }
    }

    pub fn width(&self) -> f64 {
        self.max_x - self.min_x
    }

    pub fn height(&self) -> f64 {
        self.max_y - self.min_y
    }
}

impl SplitNode {
    /// A leaf for `pane_id`.
    pub fn leaf(pane_id: impl Into<String>) -> Self {
        SplitNode::Leaf(pane_id.into())
    }

    /// A split node.
    pub fn split(
        direction: SplitDirection,
        first: SplitNode,
        second: SplitNode,
        split_percentage: f64,
    ) -> Self {
        SplitNode::Split(Box::new(SplitBranch::new(direction, first, second, split_percentage)))
    }

    // MARK: - Queries

    /// All leaf pane ids in the tree.
    pub fn leaf_ids(&self) -> HashSet<String> {
        let mut ids = HashSet::new();
        self.insert_leaf_ids(&mut ids);
        ids
    }

    /// Adds this tree's leaf pane ids to `ids`, so callers collecting several trees fill one
    /// set instead of merging one per subtree.
    pub fn insert_leaf_ids(&self, ids: &mut HashSet<String>) {
        match self {
            SplitNode::Leaf(id) => {
                ids.insert(id.clone());
            }
            SplitNode::Split(branch) => {
                branch.first.insert_leaf_ids(ids);
                branch.second.insert_leaf_ids(ids);
            }
        }
    }

    /// Leaf pane ids in visual tree order (left/top before right/bottom).
    pub fn ordered_leaf_ids(&self) -> Vec<String> {
        let mut ids = Vec::new();
        self.push_ordered_leaf_ids(&mut ids);
        ids
    }

    fn push_ordered_leaf_ids(&self, ids: &mut Vec<String>) {
        match self {
            SplitNode::Leaf(id) => ids.push(id.clone()),
            SplitNode::Split(branch) => {
                branch.first.push_ordered_leaf_ids(ids);
                branch.second.push_ordered_leaf_ids(ids);
            }
        }
    }

    /// How many panes the tree holds, without collecting their ids.
    pub fn leaf_count(&self) -> usize {
        match self {
            SplitNode::Leaf(_) => 1,
            SplitNode::Split(branch) => branch.first.leaf_count() + branch.second.leaf_count(),
        }
    }

    /// Whether `pane_id` is a leaf of this tree, without collecting the leaves first.
    pub fn contains_leaf(&self, pane_id: &str) -> bool {
        match self {
            SplitNode::Leaf(id) => id == pane_id,
            SplitNode::Split(branch) => {
                branch.first.contains_leaf(pane_id) || branch.second.contains_leaf(pane_id)
            }
        }
    }

    /// The first (leftmost/topmost) leaf in the tree.
    pub fn first_leaf(&self) -> &str {
        match self {
            SplitNode::Leaf(id) => id,
            SplitNode::Split(branch) => branch.first.first_leaf(),
        }
    }

    /// The path from the root to `pane_id`, or `None` when it is not in the tree.
    pub fn path_to(&self, pane_id: &str) -> Option<Vec<SplitBranchSide>> {
        match self {
            SplitNode::Leaf(id) => (id == pane_id).then(Vec::new),
            SplitNode::Split(branch) => {
                if let Some(mut path) = branch.first.path_to(pane_id) {
                    path.insert(0, SplitBranchSide::First);
                    return Some(path);
                }
                if let Some(mut path) = branch.second.path_to(pane_id) {
                    path.insert(0, SplitBranchSide::Second);
                    return Some(path);
                }
                None
            }
        }
    }

    /// The node at `path`, or `None` when the path leaves the tree.
    pub fn node_at(&self, path: &[SplitBranchSide]) -> Option<&SplitNode> {
        let mut current = self;
        for side in path {
            let SplitNode::Split(branch) = current else { return None };
            current = match side {
                SplitBranchSide::First => &branch.first,
                SplitBranchSide::Second => &branch.second,
            };
        }
        Some(current)
    }

    /// The split percentage of the split at `path`, or `None` when no split is there.
    pub fn split_percentage_at(&self, path: &[SplitBranchSide]) -> Option<f64> {
        match self.node_at(path)? {
            SplitNode::Split(branch) => Some(branch.split_percentage),
            SplitNode::Leaf(_) => None,
        }
    }

    // MARK: - Mutations

    /// Inserts a split at the target pane, placing the new pane as the second child.
    pub fn inserting_split(
        &self,
        target_id: &str,
        new_id: &str,
        direction: SplitDirection,
    ) -> Option<SplitNode> {
        match self {
            SplitNode::Leaf(id) => (id == target_id)
                .then(|| SplitNode::split(direction, self.clone(), SplitNode::leaf(new_id), 50.0)),
            SplitNode::Split(branch) => {
                if let Some(first) = branch.first.inserting_split(target_id, new_id, direction) {
                    let mut new_branch = branch.clone();
                    new_branch.first = first;
                    return Some(SplitNode::Split(new_branch));
                }
                if let Some(second) = branch.second.inserting_split(target_id, new_id, direction) {
                    let mut new_branch = branch.clone();
                    new_branch.second = second;
                    return Some(SplitNode::Split(new_branch));
                }
                None
            }
        }
    }

    /// Removes a pane from the tree, collapsing its parent split. `None` when nothing is left.
    pub fn removing(&self, target_id: &str) -> Option<SplitNode> {
        match self {
            SplitNode::Leaf(id) => (id != target_id).then(|| self.clone()),
            SplitNode::Split(branch) => {
                match (branch.first.removing(target_id), branch.second.removing(target_id)) {
                    (None, None) => None,
                    (None, Some(node)) | (Some(node), None) => Some(node),
                    (Some(first), Some(second)) => {
                        let mut new_branch = branch.clone();
                        new_branch.first = first;
                        new_branch.second = second;
                        Some(SplitNode::Split(new_branch))
                    }
                }
            }
        }
    }

    /// The pane that visually borders the source in `direction`.
    ///
    /// Resolved from pane geometry, not tree shape: in `H[V[a, b], V[c, d]]`, moving right
    /// from `b` lands on `d` beside it, not on `c`, the first leaf of the neighbouring subtree.
    pub fn adjacent_pane(&self, source_id: &str, direction: NavigationDirection) -> Option<String> {
        self.nearest_pane(source_id, direction, false)
    }

    /// The pane at the opposite boundary of the source's row (left/right) or column (up/down),
    /// for navigation wrapping.
    pub fn wrapping_pane(&self, source_id: &str, direction: NavigationDirection) -> Option<String> {
        self.nearest_pane(source_id, direction, true)
    }

    /// Sets the split percentage at `path`, clamped to the supported bounds.
    pub fn setting_split_percentage(&self, path: &[SplitBranchSide], percentage: f64) -> SplitNode {
        self.updating_split(path, &|branch| branch.split_percentage = clamped_percentage(percentage))
    }

    /// Adjusts the split percentage at `path` by `delta`, clamped to the supported bounds.
    pub fn adjusting_split(&self, path: &[SplitBranchSide], delta: f64) -> SplitNode {
        self.updating_split(path, &|branch| {
            branch.split_percentage = clamped_percentage(branch.split_percentage + delta)
        })
    }

    fn updating_split(&self, path: &[SplitBranchSide], update: &dyn Fn(&mut SplitBranch)) -> SplitNode {
        let SplitNode::Split(branch) = self else { return self.clone() };
        let mut branch = branch.clone();
        match path.split_first() {
            None => update(&mut branch),
            Some((SplitBranchSide::First, rest)) => branch.first = branch.first.updating_split(rest, update),
            Some((SplitBranchSide::Second, rest)) => {
                branch.second = branch.second.updating_split(rest, update)
            }
        }
        SplitNode::Split(branch)
    }

    /// Leaf frames in visual order, laid out inside `frame` by split percentages (y grows
    /// downward, matching first = top for vertical splits).
    pub fn leaf_frames(&self, frame: PaneFrame) -> Vec<(String, PaneFrame)> {
        let mut frames = Vec::new();
        self.push_leaf_frames(frame, &mut frames);
        frames
    }

    fn push_leaf_frames(&self, frame: PaneFrame, frames: &mut Vec<(String, PaneFrame)>) {
        match self {
            SplitNode::Leaf(id) => frames.push((id.clone(), frame)),
            SplitNode::Split(branch) => {
                let fraction = branch.split_percentage / 100.0;
                let mut first = frame;
                let mut second = frame;
                match branch.direction {
                    SplitDirection::Horizontal => {
                        let x = frame.min_x + frame.width() * fraction;
                        first.max_x = x;
                        second.min_x = x;
                    }
                    SplitDirection::Vertical => {
                        let y = frame.min_y + frame.height() * fraction;
                        first.max_y = y;
                        second.min_y = y;
                    }
                }
                branch.first.push_leaf_frames(first, frames);
                branch.second.push_leaf_frames(second, frames);
            }
        }
    }

    /// Picks the pane overlapping the source's row/column that is nearest in `direction` (or,
    /// when wrapping, furthest back from the opposite edge). Ties go to the pane covering the
    /// source's center, then to visual order.
    fn nearest_pane(
        &self,
        source_id: &str,
        direction: NavigationDirection,
        wrapping: bool,
    ) -> Option<String> {
        let frames = self.leaf_frames(PaneFrame::UNIT);
        let source = frames.iter().find(|(id, _)| id == source_id)?.1;

        const EPSILON: f64 = 1e-9;
        let source_span = source.span_across(direction);
        let source_center = (source_span.0 + source_span.1) / 2.0;
        let mut best: Option<(&str, f64, f64)> = None;

        for (id, frame) in frames.iter().filter(|(id, _)| id != source_id) {
            let span = frame.span_across(direction);
            if span.1.min(source_span.1) - span.0.max(source_span.0) <= EPSILON {
                continue;
            }

            let distance = if wrapping {
                match direction {
                    NavigationDirection::Right => frame.min_x,
                    NavigationDirection::Left => 1.0 - frame.max_x,
                    NavigationDirection::Down => frame.min_y,
                    NavigationDirection::Up => 1.0 - frame.max_y,
                }
            } else {
                let distance = match direction {
                    NavigationDirection::Right => frame.min_x - source.max_x,
                    NavigationDirection::Left => source.min_x - frame.max_x,
                    NavigationDirection::Down => frame.min_y - source.max_y,
                    NavigationDirection::Up => source.min_y - frame.max_y,
                };
                if distance <= -EPSILON {
                    continue;
                }
                distance
            };

            let center_offset = 0f64.max(span.0 - source_center).max(source_center - span.1);
            if let Some((_, best_distance, best_offset)) = best {
                let is_closer = distance < best_distance - EPSILON;
                let is_tied_but_centered =
                    (distance - best_distance).abs() <= EPSILON && center_offset < best_offset - EPSILON;
                if !(is_closer || is_tied_but_centered) {
                    continue;
                }
            }
            best = Some((id, distance, center_offset));
        }

        best.map(|(id, _, _)| id.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use NavigationDirection::{Down, Left, Right, Up};
    use SplitDirection::{Horizontal, Vertical};

    fn leaf(id: &str) -> SplitNode {
        SplitNode::leaf(id)
    }

    /// `H[V[a, b], V[c, d]]`.
    fn nested_layout() -> SplitNode {
        SplitNode::split(
            Horizontal,
            SplitNode::split(Vertical, leaf("a"), leaf("b"), 50.0),
            SplitNode::split(Vertical, leaf("c"), leaf("d"), 50.0),
            50.0,
        )
    }

    fn adjacent(layout: &SplitNode, from: &str, direction: NavigationDirection) -> Option<String> {
        layout.adjacent_pane(from, direction)
    }

    #[test]
    fn ordered_leaf_ids_follow_visual_tree_order() {
        let layout = SplitNode::split(
            Horizontal,
            leaf("pane-3"),
            SplitNode::split(Vertical, leaf("pane-1"), leaf("pane-2"), 50.0),
            50.0,
        );
        assert_eq!(layout.ordered_leaf_ids(), ["pane-3", "pane-1", "pane-2"]);
    }

    #[test]
    fn directional_navigation_in_two_by_two_grid_moves_to_the_visually_bordering_pane() {
        let layout = nested_layout();
        assert_eq!(adjacent(&layout, "b", Right).as_deref(), Some("d"));
        assert_eq!(adjacent(&layout, "a", Right).as_deref(), Some("c"));
        assert_eq!(adjacent(&layout, "d", Left).as_deref(), Some("b"));
        assert_eq!(adjacent(&layout, "c", Left).as_deref(), Some("a"));
        assert_eq!(adjacent(&layout, "a", Down).as_deref(), Some("b"));
        assert_eq!(adjacent(&layout, "d", Up).as_deref(), Some("c"));
        assert_eq!(adjacent(&layout, "b", Left), None);
    }

    #[test]
    fn directional_navigation_follows_uneven_split_geometry_across_stacks() {
        // Left column split at 70%, right column at 30%: from the bottom-left pane (y 0.7–1)
        // the pane beside it on the right is the bottom-right one (y 0.3–1).
        let layout = SplitNode::split(
            Horizontal,
            SplitNode::split(Vertical, leaf("a"), leaf("b"), 70.0),
            SplitNode::split(Vertical, leaf("c"), leaf("d"), 30.0),
            50.0,
        );
        assert_eq!(adjacent(&layout, "b", Right).as_deref(), Some("d"));
        assert_eq!(adjacent(&layout, "a", Right).as_deref(), Some("d"));
        assert_eq!(adjacent(&layout, "c", Left).as_deref(), Some("a"));
    }

    #[test]
    fn wrap_query_stays_in_the_source_row_or_column() {
        let layout = nested_layout();
        assert_eq!(layout.wrapping_pane("c", Right).as_deref(), Some("a"));
        assert_eq!(layout.wrapping_pane("d", Right).as_deref(), Some("b"));
        assert_eq!(layout.wrapping_pane("b", Left).as_deref(), Some("d"));
        assert_eq!(layout.wrapping_pane("b", Down).as_deref(), Some("a"));
        assert_eq!(layout.wrapping_pane("c", Up).as_deref(), Some("d"));
    }

    #[test]
    fn wrap_query_returns_none_for_singleton_and_unknown_sources() {
        assert_eq!(leaf("only").wrapping_pane("only", Left), None);
        assert_eq!(nested_layout().wrapping_pane("missing", Right), None);
    }

    #[test]
    fn setting_split_percentage_updates_only_addressed_path() {
        let layout = SplitNode::split(
            Horizontal,
            leaf("a"),
            SplitNode::split(Vertical, leaf("b"), leaf("c"), 35.0),
            40.0,
        );

        let updated = layout.setting_split_percentage(&[SplitBranchSide::Second], 72.5);

        assert_eq!(updated.split_percentage_at(&[]), Some(40.0));
        assert_eq!(updated.split_percentage_at(&[SplitBranchSide::Second]), Some(72.5));
    }

    #[test]
    fn split_percentages_clamp_on_creation_and_path_update() {
        let layout = SplitNode::split(
            Horizontal,
            leaf("a"),
            SplitNode::split(Vertical, leaf("b"), leaf("c"), 95.0),
            5.0,
        );

        assert_eq!(layout.split_percentage_at(&[]), Some(10.0));
        assert_eq!(layout.split_percentage_at(&[SplitBranchSide::Second]), Some(90.0));
        let lowered = layout.setting_split_percentage(&[SplitBranchSide::Second], -50.0);
        assert_eq!(lowered.split_percentage_at(&[SplitBranchSide::Second]), Some(10.0));
        assert_eq!(layout.setting_split_percentage(&[], 150.0).split_percentage_at(&[]), Some(90.0));
    }

    #[test]
    fn inserting_and_removing_panes_keeps_the_rest_of_the_tree() {
        let layout = leaf("a").inserting_split("a", "b", Horizontal).expect("inserted");
        let layout = layout.inserting_split("b", "c", Vertical).expect("inserted");
        assert_eq!(layout.ordered_leaf_ids(), ["a", "b", "c"]);
        assert_eq!(layout.path_to("c"), Some(vec![SplitBranchSide::Second, SplitBranchSide::Second]));
        assert!(layout.inserting_split("missing", "d", Vertical).is_none());

        let without_b = layout.removing("b").expect("panes left");
        assert_eq!(without_b, SplitNode::split(Horizontal, leaf("a"), leaf("c"), 50.0));
        assert_eq!(leaf("a").removing("a"), None);
        assert_eq!(layout.leaf_count(), 3);
        assert_eq!(layout.first_leaf(), "a");
    }

    #[test]
    fn leaf_frames_divide_the_unit_square_by_split_percentages() {
        let layout = SplitNode::split(
            Horizontal,
            leaf("a"),
            SplitNode::split(Vertical, leaf("b"), leaf("c"), 25.0),
            40.0,
        );
        let frames = layout.leaf_frames(PaneFrame::UNIT);
        assert_eq!(frames[0], ("a".to_owned(), PaneFrame { min_x: 0.0, min_y: 0.0, max_x: 0.4, max_y: 1.0 }));
        assert_eq!(
            frames[1],
            ("b".to_owned(), PaneFrame { min_x: 0.4, min_y: 0.0, max_x: 1.0, max_y: 0.25 })
        );
        assert_eq!(
            frames[2],
            ("c".to_owned(), PaneFrame { min_x: 0.4, min_y: 0.25, max_x: 1.0, max_y: 1.0 })
        );
    }
}
