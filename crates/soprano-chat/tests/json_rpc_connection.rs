#![cfg(unix)]

use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::json;
use soprano_chat::*;

fn next(events: &mpsc::Receiver<(u64, PeerEvent)>) -> PeerEvent {
    events.recv_timeout(Duration::from_secs(10)).expect("an event").1
}

/// `cat` echoes every line, so a request comes back as a request from the peer, and the reply
/// to it comes back as the response to our request.
#[test]
fn requests_and_replies_round_trip_as_newline_delimited_json() {
    let mut connection = JsonRpcConnection::new(vec!["/bin/cat".into()], None, None);
    let (sender, events) = mpsc::channel();
    connection.start(PeerSink::new(1, sender)).expect("start");

    let id = connection.request("say", json!({"text": "hi \"there\"\nnext"})).expect("request");
    let PeerEvent::Request { id: echoed, method, params } = next(&events) else {
        panic!("expected the echoed request")
    };
    assert_eq!(method, "say");
    connection.reply(echoed, Ok(json!({"echoed": params["text"]})));
    assert_eq!(
        next(&events),
        PeerEvent::Response { id, result: Ok(json!({"echoed": "hi \"there\"\nnext"})) }
    );

    connection.terminate();
    connection.wait_for_exit();
    assert!(matches!(next(&events), PeerEvent::Exit { .. }));
    assert_eq!(connection.request("late", json!({})), Err(JsonRpcError::closed()));
}

#[test]
fn requests_still_waiting_when_the_agent_exits_fail_as_closed_before_the_exit() {
    let mut connection = JsonRpcConnection::new(
        vec!["/bin/sh".into(), "-c".into(), "read line; echo boom >&2; exit 3".into()],
        None,
        None,
    );
    let (sender, events) = mpsc::channel();
    connection.start(PeerSink::new(1, sender)).expect("start");
    let id = connection.request("never", json!({})).expect("request");
    assert_eq!(next(&events), PeerEvent::Response { id, result: Err(JsonRpcError::closed()) });
    assert_eq!(next(&events), PeerEvent::Exit { status: 3, stderr: "boom".into() });
}

#[test]
fn an_agent_that_ignores_termination_is_killed_after_the_grace_period() {
    let mut connection = JsonRpcConnection::with_grace_period(
        vec!["/bin/sh".into(), "-c".into(), "trap '' TERM; while :; do sleep 1; done".into()],
        None,
        None,
        Duration::from_millis(200),
    );
    let (sender, events) = mpsc::channel();
    connection.start(PeerSink::new(1, sender)).expect("start");
    // Let the shell install its trap before the signal arrives.
    std::thread::sleep(Duration::from_millis(200));
    let started = Instant::now();
    connection.terminate();
    connection.wait_for_exit();
    assert!(started.elapsed() >= Duration::from_millis(200));
    let PeerEvent::Exit { status, .. } = next(&events) else { panic!("expected the exit") };
    assert_eq!(status, libc_sigkill());
}

fn libc_sigkill() -> i32 {
    9
}

#[test]
fn lines_split_on_newlines_and_a_partial_line_waits() {
    let mut splitter = LineSplitter::default();
    assert_eq!(splitter.append(b"{\"a\":1}\n\n{\"b\""), vec![b"{\"a\":1}".to_vec()]);
    assert_eq!(splitter.append(b":2}\n"), vec![b"{\"b\":2}".to_vec()]);
}

#[test]
fn an_agent_whose_child_still_holds_its_output_is_reported_as_exited_at_once() {
    let mut connection =
        JsonRpcConnection::new(vec!["/bin/sh".into(), "-c".into(), "sleep 30 & exit 1".into()], None, None);
    let (sender, events) = mpsc::channel();
    connection.start(PeerSink::new(1, sender)).expect("start");
    let started = Instant::now();
    let PeerEvent::Exit { status, .. } = next(&events) else { panic!("expected the exit") };
    assert_eq!(status, 1);
    assert!(started.elapsed() < Duration::from_secs(3), "exit took {:?}", started.elapsed());
    assert!(connection.has_exited());
}

#[test]
fn a_long_line_arriving_in_many_chunks_is_scanned_once() {
    let mut splitter = LineSplitter::default();
    let chunk = vec![b'x'; 4096];
    let started = Instant::now();
    for _ in 0..2_048 {
        assert!(splitter.append(&chunk).is_empty());
    }
    assert_eq!(splitter.pending_len(), 4096 * 2_048);
    let lines = splitter.append(b"\nnext");
    assert_eq!(lines.len(), 1);
    assert_eq!(lines[0].len(), 4096 * 2_048);
    assert_eq!(splitter.pending_len(), 4);
    assert!(started.elapsed() < Duration::from_secs(2), "took {:?}", started.elapsed());
}
