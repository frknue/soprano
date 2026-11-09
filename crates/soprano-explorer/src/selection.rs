//! A list selection kept by row identity (relative path), so it survives rows being
//! rebuilt: the selected rows, the anchor shift-ranges grow from, and the lead row
//! keyboard commands act on (NSOutlineView's `selectedRow`).

use std::collections::BTreeSet;

use soprano_files::tree::{move_selection_by, move_selection_to, page_step};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Selection {
    selected: Vec<String>,
    lead: Option<String>,
}

impl Selection {
    pub(crate) fn is_empty(&self) -> bool {
        self.selected.is_empty()
    }

    pub(crate) fn contains(&self, id: &str) -> bool {
        self.selected.iter().any(|selected| selected == id)
    }

    pub(crate) fn lead(&self) -> Option<&str> {
        self.lead.as_deref()
    }

    pub(crate) fn clear(&mut self) {
        self.selected.clear();
        self.lead = None;
    }

    /// The selected ids in row order (ids missing from `rows` drop out).
    pub(crate) fn in_order<'a>(&self, rows: impl IntoIterator<Item = &'a str>) -> Vec<String> {
        rows.into_iter().filter(|id| self.contains(id)).map(str::to_owned).collect()
    }

    /// Only `id`.
    pub(crate) fn select(&mut self, id: &str) {
        self.selected = vec![id.to_owned()];
        self.lead = Some(id.to_owned());
    }

    /// Exactly `ids` (those present in `rows`), the first one leading.
    pub(crate) fn select_all_of(&mut self, ids: &[String], rows: &[&str]) {
        let present: Vec<String> = ids.iter().filter(|id| rows.contains(&id.as_str())).cloned().collect();
        if present.is_empty() {
            return;
        }
        self.lead = present.first().cloned();
        self.selected = present;
    }

    /// ⌘-click: adds or removes `id`.
    pub(crate) fn toggle(&mut self, id: &str) {
        if let Some(index) = self.selected.iter().position(|selected| selected == id) {
            self.selected.remove(index);
            if self.lead.as_deref() == Some(id) {
                self.lead = self.selected.last().cloned();
            }
        } else {
            self.selected.push(id.to_owned());
            self.lead = Some(id.to_owned());
        }
    }

    /// ⇧-click: the range from the first selected row to `id`.
    pub(crate) fn extend_to(&mut self, id: &str, rows: &[&str]) {
        let Some(target) = rows.iter().position(|row| *row == id) else { return };
        let indices = self.indices(rows);
        if let Some((selection, _)) = move_selection_to(&indices, target as isize, rows.len(), true) {
            self.apply(&selection, target, rows);
        }
    }

    /// Arrow keys and Page Up/Down: moves by `delta` rows (±1, or the page step), with ⇧
    /// extending from the anchor. Returns the row to scroll to.
    pub(crate) fn move_by(&mut self, delta: isize, extending: bool, rows: &[&str]) -> Option<usize> {
        let indices = self.indices(rows);
        let (selection, target) = move_selection_by(&indices, delta, rows.len(), extending)?;
        self.apply(&selection, target, rows);
        Some(target)
    }

    /// Home/End: moves to `row` (clamped), with ⇧ extending from the anchor.
    pub(crate) fn move_to(&mut self, row: isize, extending: bool, rows: &[&str]) -> Option<usize> {
        let indices = self.indices(rows);
        let (selection, target) = move_selection_to(&indices, row, rows.len(), extending)?;
        self.apply(&selection, target, rows);
        Some(target)
    }

    pub(crate) fn page_step(rows: usize) -> isize {
        page_step(rows)
    }

    /// Row indices of the selection, as NSOutlineView keeps them (sorted); the anchor is
    /// the first.
    fn indices(&self, rows: &[&str]) -> BTreeSet<usize> {
        rows.iter().enumerate().filter(|(_, id)| self.contains(id)).map(|(index, _)| index).collect()
    }

    fn apply(&mut self, selection: &BTreeSet<usize>, lead: usize, rows: &[&str]) {
        self.selected =
            selection.iter().filter_map(|index| rows.get(*index)).map(|id| (*id).to_owned()).collect();
        self.lead = rows.get(lead).map(|id| (*id).to_owned());
    }

    /// Re-points ids after a rename or move (`old` and everything under it).
    pub(crate) fn rename(&mut self, old: &str, new: &str) {
        let prefix = format!("{old}/");
        let map = |id: &mut String| {
            if id == old {
                *id = new.to_owned();
            } else if let Some(rest) = id.strip_prefix(&prefix) {
                *id = format!("{new}/{rest}");
            }
        };
        self.selected.iter_mut().for_each(map);
        if let Some(lead) = self.lead.as_mut() {
            map(lead);
        }
    }

    /// Drops ids no longer in `rows`.
    pub(crate) fn retain_present(&mut self, rows: &[&str]) {
        self.selected.retain(|id| rows.contains(&id.as_str()));
        if self.lead.as_deref().is_some_and(|lead| !rows.contains(&lead)) {
            self.lead = self.selected.last().cloned();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROWS: [&str; 5] = ["a", "b", "c", "d", "e"];

    #[test]
    fn arrows_move_the_lead_and_shift_extends_from_the_first_selected_row() {
        let mut selection = Selection::default();
        assert_eq!(selection.move_by(1, false, &ROWS), Some(0));
        assert_eq!(selection.lead(), Some("a"));
        selection.move_by(1, false, &ROWS);
        selection.move_by(2, true, &ROWS);
        assert_eq!(selection.in_order(ROWS), ["b", "c", "d"]);
        assert_eq!(selection.lead(), Some("d"));
        assert_eq!(selection.move_to(10, false, &ROWS), Some(4));
        assert_eq!(selection.in_order(ROWS), ["e"]);
    }

    #[test]
    fn command_clicks_toggle_and_shift_clicks_extend() {
        let mut selection = Selection::default();
        selection.select("b");
        selection.toggle("d");
        assert_eq!(selection.in_order(ROWS), ["b", "d"]);
        selection.toggle("d");
        assert_eq!(selection.lead(), Some("b"));
        selection.extend_to("e", &ROWS);
        assert_eq!(selection.in_order(ROWS), ["b", "c", "d", "e"]);
    }

    #[test]
    fn renaming_a_folder_keeps_its_rows_selected() {
        let mut selection = Selection::default();
        selection.select("src/lib.rs");
        selection.rename("src", "lib");
        assert!(selection.contains("lib/lib.rs"));
        assert_eq!(selection.lead(), Some("lib/lib.rs"));
    }
}
