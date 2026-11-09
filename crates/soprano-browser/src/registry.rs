//! `BrowserPaneRegistry`: the live browser views by target, held weakly so a closed tab's view
//! goes away with its pane.

use std::collections::HashMap;

use gpui::{App, Entity, EntityId, Global, WeakEntity};

use crate::BrowserView;
use soprano_types::TerminalTarget;

/// Maps targets to weak view handles. [`BrowserView`]s register themselves when built and
/// unregister when released; it is a GPUI global, read with [`BrowserRegistry::view`].
pub type BrowserRegistry = Registry<BrowserView>;

pub struct Registry<V: 'static> {
    views: HashMap<TerminalTarget, WeakEntity<V>>,
}

impl<V: 'static> Default for Registry<V> {
    fn default() -> Self {
        Self { views: HashMap::new() }
    }
}

impl Global for Registry<BrowserView> {}

impl<V: 'static> Registry<V> {
    /// Registers `view` for `target`, replacing an earlier view there.
    pub fn register(&mut self, target: TerminalTarget, view: WeakEntity<V>) {
        self.prune();
        self.views.insert(target, view);
    }

    /// Unregisters `target` only while it still maps to `view`, so a newer view for the same tab
    /// stays registered.
    pub fn unregister(&mut self, target: &TerminalTarget, view: EntityId) {
        if self.views.get(target).is_some_and(|weak| weak.entity_id() == view) {
            self.views.remove(target);
        }
    }

    /// The live view for `target`.
    pub fn view_for(&mut self, target: &TerminalTarget) -> Option<Entity<V>> {
        self.prune();
        self.views.get(target)?.upgrade()
    }

    fn prune(&mut self) {
        self.views.retain(|_, weak| weak.upgrade().is_some());
    }
}

impl Registry<BrowserView> {
    /// The live view for `target` in the app's registry.
    pub fn view(target: &TerminalTarget, cx: &mut App) -> Option<Entity<BrowserView>> {
        cx.default_global::<Self>().view_for(target)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{AppContext as _, TestAppContext};

    struct Probe;

    #[gpui::test]
    fn views_are_found_by_target_until_they_are_released(cx: &mut TestAppContext) {
        let target = TerminalTarget::new("pane-1", "tab-1");
        let mut registry = Registry::<Probe>::default();
        let view = cx.new(|_| Probe);
        registry.register(target.clone(), view.downgrade());
        assert_eq!(registry.view_for(&target).map(|found| found.entity_id()), Some(view.entity_id()));
        assert!(registry.view_for(&TerminalTarget::new("pane-1", "tab-2")).is_none());

        drop(view);
        cx.run_until_parked();
        assert!(registry.view_for(&target).is_none());
    }

    #[gpui::test]
    fn unregistering_a_replaced_view_keeps_the_newer_one(cx: &mut TestAppContext) {
        let target = TerminalTarget::new("pane-1", "tab-1");
        let mut registry = Registry::<Probe>::default();
        let old = cx.new(|_| Probe);
        let new = cx.new(|_| Probe);
        registry.register(target.clone(), old.downgrade());
        registry.register(target.clone(), new.downgrade());

        registry.unregister(&target, old.entity_id());
        assert_eq!(registry.view_for(&target).map(|found| found.entity_id()), Some(new.entity_id()));

        registry.unregister(&target, new.entity_id());
        assert!(registry.view_for(&target).is_none());
    }
}
