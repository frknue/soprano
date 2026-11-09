//! Which row of a list the page drives with J/K, kept by id so a refresh keeps it, and a row
//! that shows up later (an automation just saved, a run coming back from its report) can be
//! selected ahead of time.

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Selection {
    selected: Option<String>,
    pending: Option<String>,
}

impl Selection {
    pub fn selected(&self) -> Option<&str> {
        self.selected.as_deref()
    }

    /// Brings the selection up to date with the rows `ids` shows: a pending id that showed up
    /// is selected, and a selection that went away falls back to the first row.
    pub fn reconcile(&mut self, ids: &[String]) {
        if let Some(pending) = &self.pending
            && ids.contains(pending)
        {
            self.selected = self.pending.take();
        }
        if !self.selected.as_ref().is_some_and(|id| ids.contains(id)) {
            self.selected = ids.first().cloned();
        }
    }

    /// Selects `id` now, or as soon as it shows up in `ids`.
    pub fn select(&mut self, id: &str, ids: &[String]) {
        if ids.iter().any(|candidate| candidate == id) {
            self.selected = Some(id.to_owned());
        } else {
            self.pending = Some(id.to_owned());
        }
    }

    /// Moves by `delta` rows, stopping at either end.
    pub fn move_by(&mut self, ids: &[String], delta: isize) {
        if ids.is_empty() {
            return;
        }
        let current = self.selected.as_ref().and_then(|id| ids.iter().position(|c| c == id)).unwrap_or(0);
        let next = current.saturating_add_signed(delta).min(ids.len() - 1);
        self.selected = Some(ids[next].clone());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(names: &[&str]) -> Vec<String> {
        names.iter().map(|n| (*n).to_owned()).collect()
    }

    #[test]
    fn moving_stops_at_either_end_and_a_gone_row_falls_back_to_the_first() {
        let rows = ids(&["a", "b", "c"]);
        let mut selection = Selection::default();
        selection.reconcile(&rows);
        assert_eq!(selection.selected(), Some("a"));
        selection.move_by(&rows, -1);
        assert_eq!(selection.selected(), Some("a"));
        selection.move_by(&rows, 5);
        assert_eq!(selection.selected(), Some("c"));
        selection.reconcile(&ids(&["a", "b"]));
        assert_eq!(selection.selected(), Some("a"));
    }

    #[test]
    fn a_row_selected_before_it_shows_up_is_selected_once_it_does() {
        let mut selection = Selection::default();
        selection.select("new", &ids(&["a"]));
        selection.reconcile(&ids(&["a"]));
        assert_eq!(selection.selected(), Some("a"));
        selection.reconcile(&ids(&["a", "new"]));
        assert_eq!(selection.selected(), Some("new"));
    }
}
