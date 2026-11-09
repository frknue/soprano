//! The right sidebar's persisted state: which panel shows, whether it is open, and how
//! wide it is (`RightSidebarView.swift`, `SidebarWidthStore.swift`, and the right-sidebar
//! parts of `MainContentViewController.swift`). No gpui; the app shell owns the frame.

use soprano_platform::StateStore;

/// The two panels of the right sidebar.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum RightSidebarTab {
    #[default]
    Explorer,
    SourceControl,
}

impl RightSidebarTab {
    pub const ALL: [Self; 2] = [Self::Explorer, Self::SourceControl];

    /// The value stored under [`ACTIVE_TAB_KEY`] (the Swift enum's raw value).
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Explorer => "explorer",
            Self::SourceControl => "sourceControl",
        }
    }

    pub fn from_raw_value(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|tab| tab.raw_value() == raw)
    }

    /// The Swift tab title.
    pub fn title(self) -> &'static str {
        match self {
            Self::Explorer => "Explorer",
            Self::SourceControl => "Source Control",
        }
    }

    /// The Herdr card title.
    pub fn card_title(self) -> &'static str {
        match self {
            Self::Explorer => "Files",
            Self::SourceControl => "Changes",
        }
    }
}

pub const ACTIVE_TAB_KEY: &str = "soprano-right-sidebar-tab";
pub const VISIBLE_KEY: &str = "soprano-right-sidebar-visible";

/// A sidebar's persisted width and the bounds a mouse drag may resize it to.
/// The left (windows) and right (explorer) sidebars each have their own.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SidebarWidthStore {
    pub default_width: f32,
    pub minimum_width: f32,
    pub maximum_width: f32,
    key: &'static str,
}

impl SidebarWidthStore {
    /// Width the tiling layout keeps for panes even when a sidebar is dragged
    /// toward the opposite edge of a narrow window.
    pub const RESERVED_CONTENT_WIDTH: f32 = 320.0;

    pub const LEFT: Self = Self {
        default_width: 220.0,
        minimum_width: 160.0,
        maximum_width: 520.0,
        key: "soprano-sidebar-width",
    };

    pub const RIGHT: Self = Self {
        default_width: 280.0,
        minimum_width: 220.0,
        maximum_width: 800.0,
        key: "soprano-right-sidebar-width",
    };

    pub fn key(&self) -> &'static str {
        self.key
    }

    /// Clamps a proposed width to the allowed range. Passing the width the sidebar may
    /// share with the panes additionally caps it so [`Self::RESERVED_CONTENT_WIDTH`] stays
    /// available for them; the minimum always wins so a very narrow window cannot collapse
    /// the sidebar into nothing (that is what toggling is for).
    pub fn clamp(&self, width: f32, available_width: Option<f32>) -> f32 {
        if !width.is_finite() {
            return self.default_width;
        }
        let mut upper_bound = self.maximum_width;
        if let Some(available) = available_width
            && available.is_finite()
            && available > 0.0
        {
            upper_bound = upper_bound.min(self.minimum_width.max(available - Self::RESERVED_CONTENT_WIDTH));
        }
        width.max(self.minimum_width).min(upper_bound)
    }

    pub fn load(&self, store: &StateStore) -> f32 {
        match store.get::<f64>(self.key) {
            Some(stored) => self.clamp(stored as f32, None),
            None => self.default_width,
        }
    }

    pub fn save(&self, width: f32, store: &StateStore) {
        store.set(self.key, &f64::from(self.clamp(width, None)));
    }
}

/// What a ⇧⌘E / ⇧⌘G press does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PanelToggle {
    /// The tab was showing and had the keyboard: the sidebar closes and the keyboard
    /// returns to the panes.
    Hide,
    /// The sidebar opens on the tab and the keyboard moves into its list.
    ShowAndFocus,
}

/// Open state, width and active tab of the right sidebar, persisted in a [`StateStore`]
/// under the Swift keys.
#[derive(Clone)]
pub struct RightSidebarState {
    store: StateStore,
    is_open: bool,
    width: f32,
    tab: RightSidebarTab,
}

impl RightSidebarState {
    pub fn load(store: StateStore) -> Self {
        let is_open = store.get::<bool>(VISIBLE_KEY).unwrap_or(true);
        let width = SidebarWidthStore::RIGHT.load(&store);
        let tab = store
            .get::<String>(ACTIVE_TAB_KEY)
            .and_then(|raw| RightSidebarTab::from_raw_value(&raw))
            .unwrap_or_default();
        Self { store, is_open, width, tab }
    }

    pub fn is_open(&self) -> bool {
        self.is_open
    }

    /// The width the sidebar has while open (its frame is 0 while closed).
    pub fn width(&self) -> f32 {
        self.width
    }

    /// The width the sidebar's frame takes now: its width when open, else 0.
    pub fn frame_width(&self) -> f32 {
        if self.is_open { self.width } else { 0.0 }
    }

    pub fn tab(&self) -> RightSidebarTab {
        self.tab
    }

    /// Opens or closes the sidebar and remembers it; returns whether anything changed.
    pub fn set_open(&mut self, open: bool) -> bool {
        if open == self.is_open {
            return false;
        }
        self.is_open = open;
        self.store.set(VISIBLE_KEY, &open);
        true
    }

    /// Shows `tab` and remembers it for the next launch; returns whether it changed.
    pub fn select_tab(&mut self, tab: RightSidebarTab) -> bool {
        if tab == self.tab {
            return false;
        }
        self.tab = tab;
        self.store.set(ACTIVE_TAB_KEY, tab.raw_value());
        true
    }

    /// Applies a dragged width, clamped to the allowed range and to what the window can
    /// spare for panes (`available_width` = window width minus the left sidebar). A hidden
    /// sidebar keeps the width it will reappear at. Returns whether the width changed.
    /// Call [`Self::save_width`] when the drag ends.
    pub fn drag_width(&mut self, proposed: f32, available_width: Option<f32>) -> bool {
        if !self.is_open {
            return false;
        }
        let width = SidebarWidthStore::RIGHT.clamp(proposed, available_width);
        if width == self.width {
            return false;
        }
        self.width = width;
        true
    }

    pub fn save_width(&self) {
        SidebarWidthStore::RIGHT.save(self.width, &self.store);
    }

    /// Double-clicking the resize edge: back to the default width (still leaving the panes
    /// their reserved room in a narrow window), saved.
    pub fn reset_width(&mut self, available_width: Option<f32>) {
        if self.is_open {
            self.drag_width(SidebarWidthStore::RIGHT.default_width, available_width);
        }
        self.save_width();
    }

    /// ⇧⌘E / ⇧⌘G: opens the sidebar on `tab` and moves the keyboard into it; pressed again
    /// while that tab shows and has the keyboard, hides the sidebar. Applies the change and
    /// returns what the caller must do with the keyboard.
    pub fn toggle_tab(&mut self, tab: RightSidebarTab, panel_has_keyboard: bool) -> PanelToggle {
        let is_showing_tab = self.is_open && self.tab == tab;
        if is_showing_tab && panel_has_keyboard {
            self.set_open(false);
            return PanelToggle::Hide;
        }
        self.select_tab(tab);
        self.set_open(true);
        PanelToggle::ShowAndFocus
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn width_clamps_to_the_allowed_range() {
        let store = SidebarWidthStore::LEFT;
        assert_eq!(store.clamp(300.0, None), 300.0);
        assert_eq!(store.clamp(10.0, None), store.minimum_width);
        assert_eq!(store.clamp(5000.0, None), store.maximum_width);
        assert_eq!(store.clamp(f32::NAN, None), store.default_width);
        assert_eq!(store.clamp(f32::INFINITY, None), store.default_width);
    }

    #[test]
    fn width_leaves_room_for_panes_in_narrow_windows() {
        let store = SidebarWidthStore::LEFT;
        // 700 wide window: the reserve binds before the absolute maximum does.
        assert_eq!(store.clamp(800.0, Some(700.0)), 380.0);
        assert_eq!(store.clamp(200.0, Some(700.0)), 200.0);
        // Wide window: the absolute maximum is what stops the drag.
        assert_eq!(store.clamp(800.0, Some(1800.0)), store.maximum_width);
        // Narrower than minimum + reserved: the minimum still wins.
        assert_eq!(store.clamp(400.0, Some(300.0)), store.minimum_width);
    }

    #[test]
    fn width_round_trips_through_the_state_store_and_falls_back_when_unset() {
        let state = StateStore::in_memory();
        let store = SidebarWidthStore::LEFT;
        assert_eq!(store.load(&state), store.default_width);
        store.save(340.0, &state);
        assert_eq!(store.load(&state), 340.0);
        // Values outside the current bounds are clamped on the way back in.
        store.save(9000.0, &state);
        assert_eq!(store.load(&state), store.maximum_width);
        // Each sidebar keeps its own width.
        assert_eq!(SidebarWidthStore::RIGHT.load(&state), SidebarWidthStore::RIGHT.default_width);
    }

    #[test]
    fn the_right_sidebar_is_280_wide_by_default_and_no_narrower_than_220() {
        assert_eq!(SidebarWidthStore::RIGHT.default_width, 280.0);
        assert_eq!(SidebarWidthStore::RIGHT.minimum_width, 220.0);
        assert_eq!(SidebarWidthStore::RIGHT.key(), "soprano-right-sidebar-width");
    }

    #[test]
    fn dragging_the_right_sidebars_edge_left_widens_it_and_the_width_survives_a_relaunch() {
        let store = StateStore::in_memory();
        let mut state = RightSidebarState::load(store.clone());
        assert_eq!(state.width(), SidebarWidthStore::RIGHT.default_width);

        // The leading edge moved 100 left: 100 wider.
        assert!(state.drag_width(state.width() + 100.0, Some(2000.0)));
        assert_eq!(state.width(), SidebarWidthStore::RIGHT.default_width + 100.0);

        // Dragged far right: stops at the minimum.
        state.drag_width(state.width() - 500.0, Some(2000.0));
        assert_eq!(state.width(), SidebarWidthStore::RIGHT.minimum_width);
        state.save_width();

        let relaunched = RightSidebarState::load(store);
        assert_eq!(relaunched.width(), SidebarWidthStore::RIGHT.minimum_width);
    }

    #[test]
    fn both_sidebars_together_still_leave_panes_the_reserved_width() {
        let right = SidebarWidthStore::RIGHT.default_width;
        let left = SidebarWidthStore::LEFT.clamp(5000.0, Some(1000.0 - right));
        assert_eq!(left, 1000.0 - right - SidebarWidthStore::RESERVED_CONTENT_WIDTH);
    }

    #[test]
    fn hiding_the_right_sidebar_collapses_it_and_reopens_at_its_width() {
        let store = StateStore::in_memory();
        let mut state = RightSidebarState::load(store.clone());
        assert!(state.is_open());
        state.drag_width(state.width() + 40.0, None);
        state.save_width();

        assert!(state.set_open(false));
        assert_eq!(state.frame_width(), 0.0);
        // Dragging a hidden sidebar does not change the width it reappears at.
        assert!(!state.drag_width(500.0, None));

        // The closed state survives a relaunch.
        assert_eq!(RightSidebarState::load(store.clone()).frame_width(), 0.0);

        assert!(state.set_open(true));
        assert_eq!(state.frame_width(), SidebarWidthStore::RIGHT.default_width + 40.0);
    }

    #[test]
    fn double_clicking_the_edge_restores_the_default_width() {
        let store = StateStore::in_memory();
        let mut state = RightSidebarState::load(store.clone());
        state.drag_width(500.0, None);
        state.save_width();
        state.reset_width(None);
        assert_eq!(state.width(), SidebarWidthStore::RIGHT.default_width);
        assert_eq!(RightSidebarState::load(store).width(), SidebarWidthStore::RIGHT.default_width);

        // A narrow window keeps the panes' reserved width even after a reset.
        let mut state = RightSidebarState::load(StateStore::in_memory());
        state.drag_width(230.0, None);
        state.reset_width(Some(560.0));
        assert_eq!(state.width(), 560.0 - SidebarWidthStore::RESERVED_CONTENT_WIDTH);
    }

    #[test]
    fn the_active_tab_is_remembered_under_the_swift_key() {
        let store = StateStore::in_memory();
        let mut state = RightSidebarState::load(store.clone());
        assert_eq!(state.tab(), RightSidebarTab::Explorer);
        assert!(state.select_tab(RightSidebarTab::SourceControl));
        assert_eq!(store.get::<String>(ACTIVE_TAB_KEY).as_deref(), Some("sourceControl"));
        assert_eq!(RightSidebarState::load(store.clone()).tab(), RightSidebarTab::SourceControl);

        store.set(ACTIVE_TAB_KEY, "bogus");
        assert_eq!(RightSidebarState::load(store).tab(), RightSidebarTab::Explorer);
    }

    #[test]
    fn toggling_a_panel_shows_and_focuses_it_and_hides_it_only_while_it_has_the_keyboard() {
        let mut state = RightSidebarState::load(StateStore::in_memory());
        state.set_open(false);

        assert_eq!(state.toggle_tab(RightSidebarTab::SourceControl, false), PanelToggle::ShowAndFocus);
        assert!(state.is_open());
        assert_eq!(state.tab(), RightSidebarTab::SourceControl);

        // Showing but the keyboard is elsewhere: focus it again rather than hiding.
        assert_eq!(state.toggle_tab(RightSidebarTab::SourceControl, false), PanelToggle::ShowAndFocus);
        assert!(state.is_open());

        // The other tab switches over even while this one has the keyboard.
        assert_eq!(state.toggle_tab(RightSidebarTab::Explorer, true), PanelToggle::ShowAndFocus);
        assert_eq!(state.tab(), RightSidebarTab::Explorer);

        assert_eq!(state.toggle_tab(RightSidebarTab::Explorer, true), PanelToggle::Hide);
        assert!(!state.is_open());
    }
}
