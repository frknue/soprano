//! A list selection kept by row identity (relative path), so it survives rows being
//! rebuilt: the selected rows, the anchor ⇧-ranges grow from, and the lead row keyboard
//! commands act on and move from (NSOutlineView's `selectedRow`).

use std::collections::HashSet;

use soprano_files::tree::page_step;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Selection {
    selected: HashSet<String>,
    anchor: Option<String>,
    lead: Option<String>,
}

impl Selection {
    pub(crate) fn is_empty(&self) -> bool {
        self.selected.is_empty()
    }

    pub(crate) fn contains(&self, id: &str) -> bool {
        self.selected.contains(id)
    }

    pub(crate) fn lead(&self) -> Option<&str> {
        self.lead.as_deref()
    }

    pub(crate) fn clear(&mut self) {
        self.selected.clear();
        self.anchor = None;
        self.lead = None;
    }

    /// The selected ids in row order (ids missing from `rows` drop out).
    pub(crate) fn in_order<'a>(&self, rows: impl IntoIterator<Item = &'a str>) -> Vec<String> {
        rows.into_iter().filter(|id| self.contains(id)).map(str::to_owned).collect()
    }

    /// Only `id`.
    pub(crate) fn select(&mut self, id: &str) {
        self.selected = HashSet::from([id.to_owned()]);
        self.anchor = Some(id.to_owned());
        self.lead = Some(id.to_owned());
    }

    /// Exactly `ids` (those present in `rows`), the first one anchoring and leading.
    pub(crate) fn select_all_of(&mut self, ids: &[String], rows: &[&str]) {
        let rows: HashSet<&str> = rows.iter().copied().collect();
        let present: Vec<&String> = ids.iter().filter(|id| rows.contains(id.as_str())).collect();
        let Some(first) = present.first() else { return };
        self.anchor = Some((*first).clone());
        self.lead = Some((*first).clone());
        self.selected = present.into_iter().cloned().collect();
    }

    /// ⌘-click: adds or removes `id`; an added row anchors and leads.
    pub(crate) fn toggle(&mut self, id: &str) {
        if self.selected.remove(id) {
            if self.lead.as_deref() == Some(id) {
                self.lead = None;
            }
            if self.anchor.as_deref() == Some(id) {
                self.anchor = None;
            }
        } else {
            self.selected.insert(id.to_owned());
            self.anchor = Some(id.to_owned());
            self.lead = Some(id.to_owned());
        }
    }

    /// ⇧-click: the range from the anchor to `id`.
    pub(crate) fn extend_to(&mut self, id: &str, rows: &[&str]) {
        let Some(target) = rows.iter().position(|row| *row == id) else { return };
        self.move_to(target as isize, true, rows);
    }

    /// Arrow keys and Page Up/Down: moves the lead by `delta` rows; with ⇧ the selection
    /// becomes the range from the anchor to the new lead. Returns the row to scroll to.
    pub(crate) fn move_by(&mut self, delta: isize, extending: bool, rows: &[&str]) -> Option<usize> {
        if rows.is_empty() {
            return None;
        }
        let current = match self.lead_index(rows) {
            Some(index) => index as isize,
            None if delta > 0 => -1,
            None => rows.len() as isize,
        };
        self.move_to(current + delta, extending, rows)
    }

    /// Home/End (and ⇧-click): moves the lead to `row` (clamped); with ⇧ the selection
    /// becomes the range from the anchor to it.
    pub(crate) fn move_to(&mut self, row: isize, extending: bool, rows: &[&str]) -> Option<usize> {
        if rows.is_empty() {
            return None;
        }
        let target = row.clamp(0, rows.len() as isize - 1) as usize;
        let anchor = self
            .anchor
            .as_deref()
            .and_then(|anchor| rows.iter().position(|id| *id == anchor))
            .or_else(|| self.lead_index(rows));
        match anchor {
            Some(anchor) if extending => {
                let range = anchor.min(target)..=anchor.max(target);
                self.selected = rows[range].iter().map(|id| (*id).to_owned()).collect();
                self.anchor = Some(rows[anchor].to_owned());
                self.lead = Some(rows[target].to_owned());
            }
            _ => self.select(rows[target]),
        }
        Some(target)
    }

    pub(crate) fn page_step(rows: usize) -> isize {
        page_step(rows)
    }

    /// The lead's row, or the last selected row when the lead was deselected.
    fn lead_index(&self, rows: &[&str]) -> Option<usize> {
        match self.lead.as_deref() {
            Some(lead) => rows.iter().position(|id| *id == lead),
            None => rows.iter().rposition(|id| self.contains(id)),
        }
    }

    /// Re-points ids after a rename or move (`old` and everything under it).
    pub(crate) fn rename(&mut self, old: &str, new: &str) {
        let prefix = format!("{old}/");
        let map = |id: &str| -> String {
            if id == old {
                new.to_owned()
            } else if let Some(rest) = id.strip_prefix(&prefix) {
                format!("{new}/{rest}")
            } else {
                id.to_owned()
            }
        };
        self.selected = self.selected.iter().map(|id| map(id)).collect();
        self.anchor = self.anchor.as_deref().map(map);
        self.lead = self.lead.as_deref().map(map);
    }

    /// Drops ids no longer in `rows`.
    pub(crate) fn retain_present(&mut self, rows: &[&str]) {
        let rows: HashSet<&str> = rows.iter().copied().collect();
        self.selected.retain(|id| rows.contains(id.as_str()));
        if self.lead.as_deref().is_some_and(|lead| !rows.contains(lead)) {
            self.lead = None;
        }
        if self.anchor.as_deref().is_some_and(|anchor| !rows.contains(anchor)) {
            self.anchor = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROWS: [&str; 5] = ["a", "b", "c", "d", "e"];

    #[test]
    fn arrows_move_the_lead_and_shift_extends_from_the_anchor() {
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
    fn shift_up_keeps_growing_the_selection_and_shrinks_back_past_the_anchor() {
        let mut selection = Selection::default();
        selection.select("e");
        selection.move_by(-1, true, &ROWS);
        selection.move_by(-1, true, &ROWS);
        selection.move_by(-1, true, &ROWS);
        assert_eq!(selection.in_order(ROWS), ["b", "c", "d", "e"]);
        assert_eq!(selection.lead(), Some("b"));
        selection.move_by(1, true, &ROWS);
        assert_eq!(selection.in_order(ROWS), ["c", "d", "e"]);

        // Shift+Page Up from the anchor: one range up to the target.
        let mut selection = Selection::default();
        selection.select("d");
        selection.move_by(-3, true, &ROWS);
        selection.move_by(-3, true, &ROWS);
        assert_eq!(selection.in_order(ROWS), ["a", "b", "c", "d"]);
    }

    #[test]
    fn command_clicks_toggle_and_shift_clicks_extend_from_the_last_clicked_row() {
        let mut selection = Selection::default();
        selection.select("b");
        selection.toggle("d");
        assert_eq!(selection.in_order(ROWS), ["b", "d"]);
        selection.toggle("d");
        assert_eq!(selection.in_order(ROWS), ["b"]);
        selection.extend_to("e", &ROWS);
        assert_eq!(selection.in_order(ROWS), ["b", "c", "d", "e"]);
        selection.extend_to("a", &ROWS);
        assert_eq!(selection.in_order(ROWS), ["a", "b"]);
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
