//! The engine without a window: a real process in a PTY, read back from the screen.

#![cfg(unix)]

use soprano_term::{Terminal, TerminalEvent, TerminalLaunch, TerminalSettings, TerminalSize};
use std::time::Duration;

fn launch(script: &str) -> TerminalLaunch {
    TerminalLaunch { argv: vec!["/bin/sh".into(), "-c".into(), script.into()], ..TerminalLaunch::default() }
}

fn spawn(launch: TerminalLaunch) -> Terminal {
    Terminal::spawn(launch, &TerminalSettings::default(), TerminalSize::default()).expect("spawn /bin/sh")
}

#[test]
fn a_spawned_command_prints_into_the_grid_and_reports_its_exit() {
    let mut terminal = spawn(launch("printf hello"));
    assert!(terminal.child_pid().is_some());
    let exited = terminal.pump_until(Duration::from_secs(10), |t| t.has_exited());
    assert!(exited, "the command exits");
    assert!(terminal.vt().visible_text().starts_with("hello"), "{:?}", terminal.vt().visible_text());
    let events = terminal.take_events();
    assert!(events.contains(&TerminalEvent::ChildExited { exit_code: Some(0) }), "{events:?}");
    assert!(events.contains(&TerminalEvent::CloseRequested));
}

#[test]
fn the_program_sees_its_environment_folder_and_size() {
    let mut launch = launch("printf '%s|%s|%s' \"$SOPRANO_TEST\" \"$(pwd -P)\" \"$(stty size)\"");
    launch.env.insert("SOPRANO_TEST".into(), "yes".into());
    launch.env.insert("PATH".into(), "/usr/bin:/bin".into());
    let dir = std::env::temp_dir().canonicalize().expect("temp dir");
    launch.cwd = Some(dir.clone());
    let mut terminal = spawn(launch);
    assert!(terminal.pump_until(Duration::from_secs(10), |t| t.has_exited()));
    let text = terminal.vt().visible_text().replace('\n', "");
    assert_eq!(text, format!("yes|{}|24 80", dir.display()));
}

#[test]
fn input_reaches_the_program_and_osc_reports_become_events() {
    let script = "read line; printf '\\033]2;%s\\007\\033]7;file:///tmp\\007\\033]9;done\\007got:%s' \"$line\" \"$line\"";
    let mut terminal = spawn(launch(script));
    terminal.write(b"ping\r");
    assert!(terminal.pump_until(Duration::from_secs(10), |t| t.has_exited()));
    assert!(terminal.vt().visible_text().contains("got:ping"), "{:?}", terminal.vt().visible_text());
    let events = terminal.take_events();
    assert!(events.contains(&TerminalEvent::TitleChanged("ping".into())), "{events:?}");
    assert!(events.contains(&TerminalEvent::WorkingDirectoryChanged("/tmp".into())));
    assert!(
        events.contains(&TerminalEvent::DesktopNotification { title: String::new(), body: "done".into() })
    );
}

#[test]
fn shell_integration_marks_drive_the_running_command_state() {
    let script = "printf '\\033]133;A\\007$ \\033]133;B\\007'; read x; printf '\\033]133;C\\007'; read y; printf '\\033]133;D;3\\007'";
    let mut terminal = spawn(launch(script));
    assert!(terminal.pump_until(Duration::from_secs(10), |t| t.vt().visible_text().contains('$')));
    assert!(!terminal.is_running_command());
    terminal.write(b"\r");
    assert!(terminal.pump_until(Duration::from_secs(10), |t| t.is_running_command()));
    terminal.write(b"\r");
    assert!(terminal.pump_until(Duration::from_secs(10), |t| t.has_exited()));
    assert!(!terminal.is_running_command());
    let events = terminal.take_events();
    assert!(events.contains(&TerminalEvent::RunningCommandChanged(true)), "{events:?}");
    assert!(events.contains(&TerminalEvent::RunningCommandChanged(false)));
    assert!(events.contains(&TerminalEvent::CommandFinished { exit_code: Some(3) }));
}

#[test]
fn wait_after_command_keeps_the_terminal_until_a_key() {
    let mut launch = launch("exit 4");
    launch.wait_after_command = true;
    let mut terminal = spawn(launch);
    assert!(terminal.pump_until(Duration::from_secs(10), |t| t.has_exited()));
    let events = terminal.take_events();
    assert!(events.contains(&TerminalEvent::ChildExited { exit_code: Some(4) }));
    assert!(!events.contains(&TerminalEvent::CloseRequested));
    assert!(terminal.waits_for_key_to_close());
    assert!(terminal.vt().visible_text().contains("Process exited"));
}

#[test]
fn an_osc52_read_waits_for_an_answer() {
    let script = "stty -echo; printf '\\033]52;c;?\\007'; read -r reply; printf 'got[%s]' \"$(printf %s \"$reply\" | tr '\\033' E)\"";
    let mut terminal = spawn(launch(script));
    let mut read = None;
    assert!(terminal.pump_until(Duration::from_secs(10), |t| {
        read = t.take_events().into_iter().find_map(|e| match e {
            TerminalEvent::ClipboardReadRequested(r) => Some(r),
            _ => None,
        });
        read.is_some()
    }));
    let read = read.expect("read request");
    terminal.answer_clipboard_read(&read, Some("hi"));
    terminal.write(b"\r");
    assert!(terminal.pump_until(Duration::from_secs(10), |t| t.has_exited()));
    assert!(terminal.vt().visible_text().contains("got[E]52;c;aGk=E"), "{:?}", terminal.vt().visible_text());
}

#[test]
fn an_exited_shell_stops_counting_as_running_a_command() {
    let script = "printf '\\033]133;A\\007$ \\033]133;B\\007\\033]133;C\\007'; sleep 0.2; exit 1";
    let mut launch = launch(script);
    launch.wait_after_command = true;
    let mut terminal = spawn(launch);
    assert!(terminal.pump_until(Duration::from_secs(10), |t| t.has_exited()));
    assert!(!terminal.is_running_command());
    let events = terminal.take_events();
    assert!(events.contains(&TerminalEvent::RunningCommandChanged(true)), "{events:?}");
    assert_eq!(events.last(), Some(&TerminalEvent::RunningCommandChanged(false)), "{events:?}");
}

#[test]
fn a_command_end_without_a_start_finishes_nothing() {
    let script = "printf '\\033]133;D;0\\007\\033]133;A\\007\\033]133;B\\007\\033]133;D\\007\\033]133;C\\007\\033]133;D;5\\007'";
    let mut terminal = spawn(launch(script));
    assert!(terminal.pump_until(Duration::from_secs(10), |t| t.has_exited()));
    let finished: Vec<_> = terminal
        .take_events()
        .into_iter()
        .filter(|e| matches!(e, TerminalEvent::CommandFinished { .. }))
        .collect();
    assert_eq!(finished, vec![TerminalEvent::CommandFinished { exit_code: Some(5) }]);
}

#[test]
fn closing_a_terminal_types_nothing_into_its_program() {
    // The program survives the hangup and would act on a line typed at close.
    let marker = std::env::temp_dir().join(format!("soprano-term-close-{}", std::process::id()));
    let _ = std::fs::remove_file(&marker);
    let script = format!(
        "trap '' HUP; printf ready; read line && printf 'got[%s]' \"$line\" > '{}'",
        marker.display()
    );
    let mut terminal = spawn(launch(&script));
    assert!(terminal.pump_until(Duration::from_secs(10), |t| t.vt().visible_text().contains("ready")));
    drop(terminal);
    std::thread::sleep(Duration::from_millis(500));
    assert!(!marker.exists(), "the program read a line nobody typed");
    let _ = std::fs::remove_file(&marker);
}

#[test]
fn a_reaped_process_is_never_signalled_again() {
    let mut terminal = spawn(launch("exit 0"));
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !terminal.process_reaped() && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(terminal.process_reaped());
    // Its exit is not handled yet (nothing was pumped), and kill must still stay away.
    assert!(!terminal.has_exited());
    terminal.kill();
}
