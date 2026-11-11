//! soprano-statistics: the statistics board (Soprano Agents' `StatisticsViewController.swift`)
//! in GPUI with Herdr's look.
//!
//! [`StatisticsBoard`] shows omp's recorded requests, tokens and estimated API-equivalent cost
//! over 24h / 7d / 30d / 90d / All, as Cost or Tokens: four headline tiles, a stacked chart per
//! hour, day, week or month, and breakdowns by model (click one to filter the board), project
//! and agent kind. It reads the history through its [`StatisticsHost`] off the main thread and
//! asks the shell to close it with a [`StatisticsEvent`].

pub mod chart;
pub mod format;
pub mod keys;
pub mod state;
mod view;

pub use keys::KeyAction;
pub use view::{FolderProvider, HistoryLoader, StatisticsBoard, StatisticsEvent, StatisticsHost, WallTime};
