//! soprano-automations-ui: the Automations page in GPUI (`Views/AutomationsViewController.swift`
//! and the views it shows): the list of automations with their schedule, folder, next and last
//! run; the New Automation templates; an automation's settings and run history; a run's report
//! rendered as Markdown; and the editor that writes `settings.json`.
//!
//! The app shell holds the [`soprano_automations::AutomationController`] and the workspace as
//! GPUI entities, renders [`AutomationsPage`] over the workspace, and answers its
//! [`AutomationsPageEvent`]s (Run Now, Open Run, Delete, Dismiss), which need the workspace.

pub mod content;
pub mod editor;
pub mod form;
pub mod format;
pub mod page;
pub mod pill;
pub mod selection;
pub mod templates;

pub use editor::{AutomationEditor, EditorClosed, EditorSetup};
pub use page::{AutomationAction, AutomationsPage, AutomationsPageEvent, Page};
pub use templates::AutomationTemplate;

#[cfg(test)]
mod page_tests;
