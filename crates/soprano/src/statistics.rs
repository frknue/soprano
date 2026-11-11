//! The app side of the statistics board: omp's usage history (`omp stats` through the login
//! shell, then its `stats.db`) and the folders the workspace works in, as the board's
//! [`StatisticsHost`].

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use gpui::Entity;
use soprano_agents::usage::OmpUsageStatistics;
use soprano_launch::{CommandRunner, RunOptions};
use soprano_model::Workspace;
use soprano_statistics::StatisticsHost;

use crate::views::sidebar::watched_cwds;

/// How long `omp stats` may take to ingest the session files written since its last run.
const SYNC_TIMEOUT: Duration = Duration::from_secs(120);

/// The board's host: omp's own records on this computer, with the usage of every folder a
/// tab works in listed under the folder's name (as the sidebar shows it).
pub fn host(workspace: Entity<Workspace>) -> StatisticsHost {
    let home = soprano_platform::paths::home_dir();
    let config_directory = std::env::var("PI_CONFIG_DIR").ok();
    let database = OmpUsageStatistics::default_database_path(config_directory.as_deref(), &home);
    let usage = OmpUsageStatistics::new(database, move || sync(&home));
    StatisticsHost::service(Arc::new(usage)).folders(move |cx| {
        watched_cwds(workspace.read(cx))
            .into_iter()
            .map(|cwd| {
                let title = soprano_model::terminal_title::folder_name(&cwd);
                (PathBuf::from(cwd), title)
            })
            .collect()
    })
}

/// `omp stats --summary`: omp ingests what it wrote since the last run, then prints a summary
/// nobody reads. Run like an agent pane's command, so omp is found on the login shell's PATH.
fn sync(home: &std::path::Path) -> Result<(), String> {
    let arguments = ["omp", "stats", "--summary"].map(String::from);
    let mut options = RunOptions::with_timeout(SYNC_TIMEOUT);
    options.working_directory = Some(home.to_path_buf());
    let result = CommandRunner::default()
        .run_cli(&arguments, &BTreeMap::new(), options)
        .map_err(|error| error.to_string())?;
    if result.succeeded() { Ok(()) } else { Err(result.failure_message_running("omp")) }
}
