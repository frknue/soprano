//! Soprano, the app (`main.swift`): a CLI subcommand runs and exits; otherwise the app starts.
//!
//! # Architecture
//!
//! - [`app`]: startup (`AppDelegate`): settings.json, accounts, theme, the restored workspace,
//!   notifications, the CLI socket, the main window; quit and close save the workspace.
//! - [`workspace`]: `soprano_model::Workspace` as a GPUI entity plus a bus. Every mutation goes
//!   through `WorkspaceHandle::update`, which drains the model's change log, notifies the
//!   entity (views re-render) and publishes a `WorkspaceUpdate` (the shell and the content
//!   host act on layout changes, lifecycle events and document moves).
//! - [`shell`]: the chrome state every view reads (sidebar, keybinding mode, held Control,
//!   pages, popups) and `Command`, the one funnel for app-level work.
//! - [`main_view`]: the window root (`MainWindowController` + `MainContentViewController`): the
//!   Herdr layout, command execution, closes with confirmation, prompts, pickers, Settings,
//!   toasts, keyboard routing through `soprano_keys::KeybindingResolver` (a keystroke
//!   interceptor ahead of every content view), IPC requests and notification routing.
//! - [`content`]: each pane tab's content entity (terminal, browser, chat, editor, diff,
//!   Markdown reader) cached by exact pane/tab target across layout rebuilds; terminal reports
//!   flow back into the workspace; it also mirrors unsaved editor documents for the model's
//!   close-confirmation predicate (the main view asks Save / Don't Save / Cancel).
//! - [`automations`]: the `AutomationHost` over the workspace and content host, and `drive`,
//!   the one way the main view calls the automation controller.
//! - [`statistics`]: the statistics board's host: omp's usage history and the workspace's
//!   folders.
//! - [`views`]: the sidebar, the window and layout tab rows, the split tree, pane headers and
//!   the status bar.
//! - [`palette`], [`menus`], [`ipc`], [`keyboard`], [`sizing`], [`window_chrome`]: the command
//!   palette's items and pickers, the macOS menu bar, the CLI requests' model logic, key event
//!   conversion, window geometry, and the per-OS window frame.

mod app;
mod automations;
mod content;
#[cfg(feature = "visual-snapshot")]
mod debug_input;
mod ipc;
mod keyboard;
mod main_view;
mod menus;
mod palette;
mod power;
mod services;
mod shell;
mod sizing;
#[cfg(feature = "visual-snapshot")]
mod snapshot;
mod statistics;
mod terminate;
mod views;
mod window_chrome;
mod workspace;

use soprano_ipc::CliOutcome;

fn main() {
    match soprano_ipc::cli::run_cli_from_process() {
        CliOutcome::Exit(code) => std::process::exit(code),
        CliOutcome::StartApp => app::run(),
    }
}
