//! The app side of the CLI ↔ app socket: the server on `endpoint_for_pid(pid)` and the model
//! logic of each request (`MarkdownCommandController.open`, `BrowserAutomationController`,
//! pane navigation). The main view hops every request onto the UI thread and calls these.

use std::path::Path;

use soprano_browser::{BrowserTarget, PaneTabs};
use soprano_ipc::transport::{Endpoint, Incoming, IpcServer, endpoint_for_pid};
use soprano_ipc::{NavigationDirection as IpcDirection, Response};
use soprano_model::{NavigationDirection, Workspace};

/// Starts listening for this process; requests arrive on the returned channel (UI side).
pub fn start_server() -> Option<(IpcServer, async_channel::Receiver<Incoming>)> {
    let endpoint: Endpoint = endpoint_for_pid(std::process::id());
    match IpcServer::start(endpoint) {
        Ok((server, receiver)) => {
            let (sender, async_receiver) = async_channel::unbounded();
            std::thread::Builder::new()
                .name("soprano-ipc-forward".into())
                .spawn(move || {
                    while let Ok(incoming) = receiver.recv() {
                        if sender.send_blocking(incoming).is_err() {
                            break;
                        }
                    }
                })
                .ok()?;
            Some((server, async_receiver))
        }
        Err(error) => {
            tracing::error!("cannot listen for CLI requests: {error}");
            None
        }
    }
}

pub fn navigation_direction(direction: IpcDirection) -> NavigationDirection {
    match direction {
        IpcDirection::Left => NavigationDirection::Left,
        IpcDirection::Right => NavigationDirection::Right,
        IpcDirection::Up => NavigationDirection::Up,
        IpcDirection::Down => NavigationDirection::Down,
    }
}

/// `soprano pane-navigation <dir>` from a terminal: moves only when that terminal is the active
/// tab, so a stale or background shell never steals focus.
pub fn navigate_pane(workspace: &mut Workspace, pane_id: &str, tab_id: &str, direction: IpcDirection) {
    let active_pane = workspace.active_pane_id().to_owned();
    let is_active = active_pane == pane_id
        && workspace.pane(pane_id).and_then(|pane| pane.active_tab()).is_some_and(|tab| tab.id == tab_id);
    if is_active {
        workspace.navigate_to_pane(navigation_direction(direction));
    }
}

/// `soprano markdown <file> [--new]` (`MarkdownCommandController.open`).
pub fn open_markdown(
    workspace: &mut Workspace,
    path: &Path,
    opens_new_pane: bool,
    caller_pane_id: Option<&str>,
    caller_tab_id: Option<&str>,
) -> Response {
    if !soprano_ipc::markdown::validate_readable_file(path) {
        return Response::failure(format!("Cannot read Markdown file: {}", path.display()));
    }
    let owner = caller_pane_id.map(str::to_owned).unwrap_or_else(|| workspace.active_pane_id().to_owned());
    let Some(pane) = workspace.pane(&owner) else {
        return Response::failure("The calling terminal is no longer available.");
    };
    if let Some(tab_id) = caller_tab_id
        && !pane.tabs.iter().any(|tab| tab.id == tab_id)
    {
        return Response::failure("The calling terminal is no longer available.");
    }
    if !opens_new_pane {
        return match workspace.preview_markdown(path, &owner) {
            Some(pane_id) => Response::success(pane_id),
            None => Response::failure("Could not open a Markdown reader (tab limit reached)."),
        };
    }
    match caller_tab_id {
        Some(tab_id) => workspace.focus_tab(&owner, tab_id, false),
        None => workspace.focus_pane(&owner),
    }
    match workspace.spawn_markdown(path, None) {
        Some(pane_id) => Response::success(pane_id),
        None => Response::failure("Could not create a Markdown reader (pane limit reached)."),
    }
}

/// The browser tab a `soprano browser` command runs in, or the message why none does.
pub fn browser_target(
    workspace: &Workspace,
    requested_pane_id: Option<&str>,
) -> Result<BrowserTarget, String> {
    let leaves: Vec<String> = workspace.layout().map(|layout| layout.ordered_leaf_ids()).unwrap_or_default();
    soprano_browser::resolve_target(requested_pane_id, workspace.active_pane_id(), &leaves, |pane_id| {
        let pane = workspace.pane(pane_id)?;
        Some(PaneTabs {
            active_tab_id: pane.active_tab().map(|tab| tab.id.clone()),
            tabs: pane.tabs.iter().map(|tab| (tab.id.clone(), tab.is_web_browser())).collect(),
        })
    })
    .ok_or_else(|| soprano_browser::no_target_message(requested_pane_id))
}

/// `open` / `open-split` / `new`: a browser pane at the URL; the reply is the new pane's id.
pub fn open_browser(workspace: &mut Workspace, arguments: &[String]) -> Response {
    match workspace.spawn_browser(arguments.first().map(String::as_str)) {
        Some(pane_id) => Response::success(pane_id),
        None => Response::failure(soprano_browser::PANE_LIMIT_MESSAGE),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_model::PaneType;

    fn markdown_file() -> (tempfile::TempDir, std::path::PathBuf) {
        let dir = tempfile::tempdir().expect("temp");
        let path = dir.path().join("README.md");
        std::fs::write(&path, "# Hello").expect("write");
        (dir, path)
    }

    #[test]
    fn an_unreadable_markdown_file_is_refused_with_its_path() {
        let mut workspace = Workspace::new();
        let response = open_markdown(&mut workspace, Path::new("/no/such/file.md"), false, None, None);
        assert_eq!(response, Response::failure("Cannot read Markdown file: /no/such/file.md"));
    }

    #[test]
    fn a_vanished_calling_terminal_is_reported() {
        let (_dir, path) = markdown_file();
        let mut workspace = Workspace::new();
        let response = open_markdown(&mut workspace, &path, false, Some("pane-404"), None);
        assert_eq!(response, Response::failure("The calling terminal is no longer available."));
        let pane = workspace.active_pane_id().to_owned();
        let response = open_markdown(&mut workspace, &path, false, Some(&pane), Some("tab-404"));
        assert_eq!(response, Response::failure("The calling terminal is no longer available."));
    }

    #[test]
    fn markdown_previews_into_the_calling_pane_and_new_opens_a_reader_pane() {
        let (_dir, path) = markdown_file();
        let mut workspace = Workspace::new();
        let pane = workspace.active_pane_id().to_owned();
        let tab = workspace.pane(&pane).and_then(|p| p.active_tab()).map(|t| t.id.clone()).expect("tab");
        let Response::Ok { output } = open_markdown(&mut workspace, &path, false, Some(&pane), Some(&tab))
        else {
            panic!("preview failed")
        };
        assert!(!output.is_empty());
        assert!(workspace.panes().values().any(|p| p.tabs.iter().any(|t| t.is_markdown())));
        let panes_before = workspace.pane_count();
        let Response::Ok { output } = open_markdown(&mut workspace, &path, true, Some(&pane), Some(&tab))
        else {
            panic!("reader failed")
        };
        assert_eq!(workspace.pane_count(), panes_before + 1);
        assert!(workspace.pane(&output).and_then(|p| p.active_tab()).is_some_and(|t| t.is_markdown()));
    }

    #[test]
    fn browser_commands_without_a_browser_explain_how_to_open_one() {
        let workspace = Workspace::new();
        assert_eq!(
            browser_target(&workspace, None),
            Err("No browser pane exists. Run `soprano browser open [url]` first.".to_owned())
        );
        let pane = workspace.active_pane_id().to_owned();
        assert_eq!(browser_target(&workspace, Some(&pane)), Err(format!("No browser tab exists in {pane}.")));
    }

    #[test]
    fn opening_a_browser_replies_with_its_pane_and_later_commands_find_it() {
        let mut workspace = Workspace::new();
        let Response::Ok { output: pane } = open_browser(&mut workspace, &["https://example.com".into()])
        else {
            panic!("no browser")
        };
        let target = browser_target(&workspace, None).expect("target");
        assert_eq!(target.pane_id, pane);
        assert_eq!(
            workspace.pane(&pane).and_then(|p| p.active_tab()).map(|t| t.pane_type),
            Some(PaneType::Browser)
        );
    }

    #[test]
    fn navigation_from_a_background_terminal_is_ignored() {
        let mut workspace = Workspace::new();
        let first = workspace.active_pane_id().to_owned();
        let first_tab =
            workspace.pane(&first).and_then(|p| p.active_tab()).map(|t| t.id.clone()).expect("tab");
        let second = workspace.spawn_terminal(None).expect("second pane");
        assert_eq!(workspace.active_pane_id(), second);
        navigate_pane(&mut workspace, &first, &first_tab, IpcDirection::Left);
        assert_eq!(workspace.active_pane_id(), second);
        let second_tab =
            workspace.pane(&second).and_then(|p| p.active_tab()).map(|t| t.id.clone()).expect("tab");
        navigate_pane(&mut workspace, &second, &second_tab, IpcDirection::Left);
        assert_eq!(workspace.active_pane_id(), first);
    }
}
