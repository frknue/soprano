//! One terminal without a window: libghostty-vt state fed by a process in an in-process
//! PTY (ConPTY on Windows, openpty elsewhere), with the program's reports as events.

use crate::events::TerminalEvent;
use crate::interaction::CommandActivity;
use crate::osc::{Osc52Read, OscScanner, ScannedOsc};
use crate::program_status::{CAPABILITY_REPLY, ProgramStatusMessage};
use crate::settings::TerminalSettings;
use crate::vt::{PromptStep, Vt, VtEvent, VtSettings};
use anyhow::{Context as _, Result};
use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize};
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// How to start a terminal's process (what `soprano-launch` builds).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TerminalLaunch {
    /// Program and arguments; `argv[0]` is looked up on `env["PATH"]`. Empty: the user's
    /// login shell.
    pub argv: Vec<String>,
    /// Working directory; `None` is the home folder.
    pub cwd: Option<PathBuf>,
    /// The complete environment of the process. Empty: this process's environment.
    pub env: BTreeMap<String, String>,
    /// Typed into the program once it starts (a launch script plus its newline).
    pub initial_input: Option<String>,
    /// Keep the terminal open after the process exits until a key is pressed (Ghostty's
    /// `wait-after-command`).
    pub wait_after_command: bool,
}

/// A grid size, with the cell in device pixels (programs ask for it, kitty images use it).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TerminalSize {
    pub cols: u16,
    pub rows: u16,
    pub cell_width: u32,
    pub cell_height: u32,
}

impl Default for TerminalSize {
    fn default() -> Self {
        Self { cols: 80, rows: 24, cell_width: 8, cell_height: 16 }
    }
}

/// What the PTY threads hand the terminal.
#[derive(Debug)]
pub enum PtyMessage {
    Data(Vec<u8>),
    /// The process exited (after its last output was read, or a short grace period).
    Exited(Option<i32>),
}

/// Output messages (up to 64 KiB each) waiting to be parsed before the reader stalls.
const OUTPUT_QUEUE: usize = 16;

/// The line Ghostty shows under a finished process it keeps open.
const WAIT_AFTER_COMMAND_NOTICE: &[u8] = b"\r\n[Process exited. Press any key to close the terminal.]";

pub struct Terminal {
    vt: Vt,
    master: Box<dyn MasterPty + Send>,
    writer: std::sync::mpsc::Sender<Vec<u8>>,
    killer: Box<dyn ChildKiller + Send + Sync>,
    /// Set once the waiter thread reaped the process.
    reaped: Arc<AtomicBool>,
    child_pid: Option<u32>,
    rx: async_channel::Receiver<PtyMessage>,
    osc: OscScanner,
    events: Vec<TerminalEvent>,
    activity: CommandActivity,
    at_prompt: bool,
    running_command: bool,
    /// A command started (OSC 133;C) and hasn't ended yet.
    command_started: bool,
    exit_status: Option<Option<i32>>,
    wait_after_command: bool,
    size: TerminalSize,
}

impl Terminal {
    /// Starts `launch` in a new PTY of `size`.
    pub fn spawn(launch: TerminalLaunch, settings: &TerminalSettings, size: TerminalSize) -> Result<Self> {
        let pty = portable_pty::native_pty_system();
        let pair = pty.openpty(pty_size(size)).context("cannot open a pseudo-terminal")?;
        let mut command = if launch.argv.is_empty() {
            CommandBuilder::new_default_prog()
        } else {
            CommandBuilder::from_argv(launch.argv.iter().map(Into::into).collect())
        };
        if !launch.env.is_empty() {
            command.env_clear();
            for (key, value) in &launch.env {
                command.env(key, value);
            }
        }
        command.cwd(launch.cwd.clone().unwrap_or_else(soprano_platform::paths::home_dir));
        let mut child = pair.slave.spawn_command(command).context("cannot start the terminal's program")?;
        // The child holds its own copy; ours would keep the PTY open after it exits.
        drop(pair.slave);
        let child_pid = child.process_id();
        let killer = child.clone_killer();
        let master = pair.master;
        let mut reader = master.try_clone_reader().context("cannot read the pseudo-terminal")?;
        let pty_writer = pty_writer(master.as_ref())?;

        // Bounded: when output outpaces parsing, the reader stalls and the PTY pushes back
        // on the program instead of memory growing without limit.
        let (tx, rx) = async_channel::bounded(OUTPUT_QUEUE);
        let reaped = Arc::new(AtomicBool::new(false));
        let reaped_by_waiter = reaped.clone();
        let (read_done_tx, read_done_rx) = std::sync::mpsc::channel::<()>();
        let data_tx = tx.clone();
        std::thread::Builder::new()
            .name("soprano-term-pty-read".into())
            .spawn(move || {
                let mut buf = vec![0u8; 64 * 1024];
                loop {
                    match reader.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => {
                            if data_tx.send_blocking(PtyMessage::Data(buf[..n].to_vec())).is_err() {
                                break;
                            }
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(_) => break,
                    }
                }
                let _ = read_done_tx.send(());
            })
            .context("cannot start the PTY reader")?;
        std::thread::Builder::new()
            .name("soprano-term-pty-wait".into())
            .spawn(move || {
                let code = child.wait().ok().map(|status| status.exit_code() as i32);
                // Its PID is free for reuse from now on: never signal it again.
                reaped_by_waiter.store(true, Ordering::SeqCst);
                // Let the reader hand over the last output first; a background job that
                // keeps the PTY open must not hold back the exit for long.
                let _ = read_done_rx.recv_timeout(Duration::from_millis(300));
                let _ = tx.send_blocking(PtyMessage::Exited(code));
            })
            .context("cannot start the PTY waiter")?;
        let (writer, writes) = std::sync::mpsc::channel::<Vec<u8>>();
        std::thread::Builder::new()
            .name("soprano-term-pty-write".into())
            .spawn(move || {
                // Writes block while the program isn't reading; never on the UI thread.
                let mut pty_writer = pty_writer;
                for bytes in writes {
                    if pty_writer.write_all(&bytes).and_then(|_| pty_writer.flush()).is_err() {
                        break;
                    }
                }
            })
            .context("cannot start the PTY writer")?;

        let mut vt = Vt::new(size.cols, size.rows, &VtSettings::from(settings));
        vt.set_option_as_alt(settings.option_as_alt);
        vt.resize(size.cols, size.rows, size.cell_width, size.cell_height);
        let terminal = Terminal {
            vt,
            master,
            writer,
            killer,
            reaped,
            child_pid,
            rx,
            osc: OscScanner::default(),
            events: Vec::new(),
            activity: CommandActivity::default(),
            at_prompt: false,
            running_command: false,
            command_started: false,
            exit_status: None,
            wait_after_command: launch.wait_after_command,
            size,
        };
        if let Some(input) = launch.initial_input.filter(|i| !i.is_empty()) {
            terminal.write(input.as_bytes());
        }
        Ok(terminal)
    }

    pub fn vt(&self) -> &Vt {
        &self.vt
    }

    pub fn vt_mut(&mut self) -> &mut Vt {
        &mut self.vt
    }

    /// Where PTY output and the exit arrive; the view awaits it.
    pub fn receiver(&self) -> async_channel::Receiver<PtyMessage> {
        self.rx.clone()
    }

    /// Feeds one message from [`Terminal::receiver`].
    pub fn handle(&mut self, message: PtyMessage) {
        match message {
            PtyMessage::Data(bytes) => self.process_output(&bytes),
            PtyMessage::Exited(code) => {
                if self.exit_status.is_some() {
                    return;
                }
                self.exit_status = Some(code);
                self.events.push(TerminalEvent::ChildExited { exit_code: code });
                // A finished process runs no command, whatever its last prompt mark said.
                self.command_started = false;
                if self.running_command {
                    self.running_command = false;
                    self.events.push(TerminalEvent::RunningCommandChanged(false));
                }
                if self.wait_after_command {
                    self.vt.write(WAIT_AFTER_COMMAND_NOTICE);
                } else {
                    self.events.push(TerminalEvent::CloseRequested);
                }
            }
        }
    }

    /// Feeds everything already received, without waiting. Returns whether anything came.
    pub fn pump(&mut self) -> bool {
        let mut any = false;
        while let Ok(message) = self.rx.try_recv() {
            self.handle(message);
            any = true;
        }
        any
    }

    /// Feeds output until `done` holds or `timeout` passes (headless use and tests).
    pub fn pump_until(&mut self, timeout: Duration, mut done: impl FnMut(&mut Terminal) -> bool) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            self.pump();
            if done(self) {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// The program's output: into the screen, its replies back, its reports as events.
    pub fn process_output(&mut self, bytes: &[u8]) {
        for found in self.osc.scan(bytes) {
            match found {
                ScannedOsc::ClipboardRead(read) => {
                    self.events.push(TerminalEvent::ClipboardReadRequested(read))
                }
                ScannedOsc::ProgramStatus(ProgramStatusMessage::Report(status)) => {
                    self.events.push(TerminalEvent::ProgramStatus(status))
                }
                ScannedOsc::ProgramStatus(ProgramStatusMessage::Query) => self.write(CAPABILITY_REPLY),
            }
        }
        self.vt.write(bytes);
        let replies = self.vt.take_replies();
        if !replies.is_empty() {
            self.write(&replies);
        }
        for event in self.vt.take_events() {
            self.translate(event);
        }
    }

    fn translate(&mut self, event: VtEvent) {
        match event {
            VtEvent::Title(title) => self.events.push(TerminalEvent::TitleChanged(title)),
            VtEvent::Pwd(raw) => {
                if let Some(path) = crate::osc::decode_pwd(&raw) {
                    self.events.push(TerminalEvent::WorkingDirectoryChanged(path));
                }
            }
            VtEvent::Bell => self.events.push(TerminalEvent::Bell),
            VtEvent::DesktopNotification { title, body } => {
                self.events.push(TerminalEvent::DesktopNotification { title, body })
            }
            VtEvent::Prompt { step, exit_code } => {
                self.at_prompt = !matches!(step, PromptStep::OutputStart);
                match step {
                    PromptStep::OutputStart => self.command_started = true,
                    // As Ghostty: an end without a start (shells mark one at the first
                    // prompt, on an empty Enter, on Ctrl-C) finished nothing.
                    PromptStep::CommandEnd if std::mem::take(&mut self.command_started) => {
                        self.events.push(TerminalEvent::CommandFinished { exit_code });
                    }
                    _ => {}
                }
                let running = self.activity.is_running_command(self.at_prompt);
                if running != self.running_command {
                    self.running_command = running;
                    self.events.push(TerminalEvent::RunningCommandChanged(running));
                }
            }
            VtEvent::ClipboardWrite { location, text } => {
                self.events.push(TerminalEvent::ClipboardWrite { location, text })
            }
            VtEvent::Reset => {
                self.events.push(TerminalEvent::TitleChanged(String::new()));
            }
        }
    }

    /// What happened since the last call, in order.
    pub fn take_events(&mut self) -> Vec<TerminalEvent> {
        std::mem::take(&mut self.events)
    }

    /// Sends bytes to the program as if typed.
    pub fn write(&self, bytes: &[u8]) {
        if !bytes.is_empty() {
            let _ = self.writer.send(bytes.to_vec());
        }
    }

    /// Answers an OSC 52 read: the clipboard's text, or `None` when denied (the program
    /// reads an empty clipboard).
    pub fn answer_clipboard_read(&self, read: &Osc52Read, text: Option<&str>) {
        self.write(&read.reply(text.unwrap_or("")));
    }

    /// Resizes the screen and tells the program (SIGWINCH, and mode 2048 reports).
    pub fn resize(&mut self, size: TerminalSize) {
        if size == self.size || size.cols == 0 || size.rows == 0 {
            return;
        }
        self.size = size;
        self.vt.resize(size.cols, size.rows, size.cell_width, size.cell_height);
        if let Err(e) = self.master.resize(pty_size(size)) {
            tracing::warn!("cannot resize the pseudo-terminal: {e:#}");
        }
        // Mode 2048 programs wait for this report, not SIGWINCH.
        let replies = self.vt.take_replies();
        self.write(&replies);
    }

    pub fn size(&self) -> TerminalSize {
        self.size
    }

    pub fn child_pid(&self) -> Option<u32> {
        self.child_pid
    }

    /// The exit code once the process exited (`Some(None)`: exited without a code).
    pub fn exit_status(&self) -> Option<Option<i32>> {
        self.exit_status
    }

    pub fn has_exited(&self) -> bool {
        self.exit_status.is_some()
    }

    /// Whether the terminal waits for a key after its process exited.
    pub fn waits_for_key_to_close(&self) -> bool {
        self.wait_after_command && self.exit_status.is_some()
    }

    /// Whether the shell runs a command rather than waiting at its prompt (shell
    /// integration's marks; false until a prompt was seen).
    pub fn is_running_command(&self) -> bool {
        self.running_command
    }

    /// The process in the foreground of the terminal (the shell, or what it runs).
    pub fn foreground_pid(&self) -> Option<u32> {
        #[cfg(unix)]
        {
            self.master.process_group_leader().filter(|pid| *pid > 0).map(|pid| pid as u32).or(self.child_pid)
        }
        #[cfg(not(unix))]
        {
            self.child_pid
        }
    }

    /// The foreground process's name (`vim`, `zsh`), where the OS tells.
    pub fn foreground_process_name(&self) -> Option<String> {
        crate::os::process_name(self.foreground_pid()?)
    }

    /// The foreground process's working directory, where the OS tells.
    pub fn foreground_cwd(&self) -> Option<PathBuf> {
        crate::os::process_cwd(self.foreground_pid()?)
    }

    /// Ends the process (the terminal closes).
    pub fn kill(&mut self) {
        // Once reaped, the PID may belong to another process.
        if self.exit_status.is_none() && !self.process_reaped() {
            let _ = self.killer.kill();
        }
    }

    /// Whether the process was reaped (it exited; its exit may not be handled yet).
    pub fn process_reaped(&self) -> bool {
        self.reaped.load(Ordering::SeqCst)
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        self.kill();
    }
}

/// Where input to the program goes. On unix a duplicate of the master: portable-pty's own
/// writer types a newline and EOF into the PTY when dropped, and a foreground job (python,
/// psql) that reads them before its SIGHUP would run a half-typed line.
#[cfg(unix)]
fn pty_writer(master: &(dyn MasterPty + Send)) -> Result<Box<dyn Write + Send>> {
    use std::os::fd::FromRawFd;
    let fd = master.as_raw_fd().context("the pseudo-terminal has no descriptor")?;
    let dup = unsafe { libc::dup(fd) };
    if dup < 0 {
        return Err(std::io::Error::last_os_error()).context("cannot write the pseudo-terminal");
    }
    // SAFETY: `dup` is a fresh descriptor that only this File owns.
    Ok(Box::new(unsafe { std::fs::File::from_raw_fd(dup) }))
}

#[cfg(not(unix))]
fn pty_writer(master: &(dyn MasterPty + Send)) -> Result<Box<dyn Write + Send>> {
    master.take_writer().context("cannot write the pseudo-terminal")
}

fn pty_size(size: TerminalSize) -> PtySize {
    let px = |cells: u16, cell: u32| u16::try_from(u32::from(cells) * cell).unwrap_or(u16::MAX);
    PtySize {
        rows: size.rows,
        cols: size.cols,
        pixel_width: px(size.cols, size.cell_width),
        pixel_height: px(size.rows, size.cell_height),
    }
}
