//! What a terminal tells its host.

use crate::clipboard::ClipboardConfirmationKind;
use crate::osc::Osc52Read;
use crate::vt::ClipboardLocation;
use soprano_types::KeybindingState;

/// A clipboard question waiting for the user (an unsafe paste, an OSC 52 read or write).
/// The host shows it (see [`crate::ClipboardConfirmationCoordinator`], enqueued with the
/// view's `entity_id().as_u64()` as the surface) and answers with
/// `TerminalView::resolve_clipboard_request(id, allowed, cx)`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClipboardRequest {
    pub id: u64,
    pub kind: ClipboardConfirmationKind,
    /// What would be pasted, read or written.
    pub content: String,
}

#[derive(Clone, Debug, PartialEq)]
pub enum TerminalEvent {
    /// OSC 0 / OSC 2 set the title.
    TitleChanged(String),
    /// The shell reported its working directory (OSC 7, decoded to a local path).
    WorkingDirectoryChanged(String),
    /// OSC 9 / OSC 777;notify.
    DesktopNotification {
        title: String,
        body: String,
    },
    /// An OSC 7501 program status report (the Program Status Protocol).
    ProgramStatus(crate::program_status::ProgramStatus),
    Bell,
    /// Shell integration: a command finished (OSC 133;D), with its exit code when reported.
    CommandFinished {
        exit_code: Option<i32>,
    },
    /// The shell started or stopped running a command. Only once the shell has shown a
    /// prompt does a terminal count as running (see `CommandActivity`).
    RunningCommandChanged(bool),
    /// The terminal's process exited.
    ChildExited {
        exit_code: Option<i32>,
    },
    /// The terminal is done: its process exited and, with `wait_after_command`, a key was
    /// pressed after that. The host closes the pane.
    CloseRequested,
    /// The program wrote the clipboard (OSC 52). `TerminalView` handles this itself (writes
    /// or asks per `clipboard-write`); a headless [`crate::Terminal`] reports it.
    ClipboardWrite {
        location: ClipboardLocation,
        text: String,
    },
    /// The program asked to read the clipboard (OSC 52 `?`). `TerminalView` handles this
    /// itself; a headless terminal answers with [`crate::Terminal::answer_clipboard_read`].
    ClipboardReadRequested(Osc52Read),
    /// A clipboard action needs the user's confirmation.
    ClipboardConfirmationRequested(ClipboardRequest),
    /// Return (without Shift) was typed into the program, or text was submitted.
    AgentInputSubmitted,
    /// Copy mode began, started selecting, or ended.
    CopyModeStateChanged(KeybindingState),
    /// A click in the terminal: the host makes its pane the active one.
    FocusRequested,
    /// The terminal gained keyboard focus in the active window.
    Focused,
    /// `destroy` ended the terminal (also the old process on `restart`). Clipboard prompts
    /// still queued for it must go: call
    /// `ClipboardConfirmationCoordinator::cancel_requests(view.entity_id().as_u64())`, or
    /// hand the view the coordinator (`TerminalView::set_clipboard_coordinator`) so it does.
    Destroyed,
}
