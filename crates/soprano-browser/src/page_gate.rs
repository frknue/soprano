//! Holds scripts back until the web view's first navigation has started.
//!
//! Until then wry queues `eval` calls and drops their callbacks, running the scripts later with
//! their results discarded: a `click` the CLI was told had failed would still happen. Scripts
//! instead wait here for the first page-load start, at most [`PAGE_START_TIMEOUT`]; a script
//! that times out is never run.

use std::time::Duration;

use gpui::{BackgroundExecutor, Task};

/// How long a script waits for the first page to start loading. Shorter than the CLI's
/// 15-second reply timeout, so a script whose request was reported failed never runs.
pub const PAGE_START_TIMEOUT: Duration = Duration::from_secs(10);

/// The answer when the first page did not start loading in time.
pub const PAGE_NOT_STARTED_MESSAGE: &str = "The page has not started loading yet";

/// Whether the first navigation has started, and who is waiting for it.
#[derive(Default)]
pub struct PageGate {
    started: bool,
    waiters: Vec<async_channel::Sender<()>>,
}

impl PageGate {
    pub fn is_open(&self) -> bool {
        self.started
    }

    /// Marks the first navigation started and releases every waiter.
    pub fn open(&mut self) {
        self.started = true;
        for waiter in self.waiters.drain(..) {
            let _ = waiter.try_send(());
        }
    }

    /// Resolves once the gate is open: `Ok` right away when it already is, `Err` after `timeout`
    /// or when the gate is dropped (the view went away).
    pub fn wait(&mut self, executor: &BackgroundExecutor, timeout: Duration) -> Task<Result<(), String>> {
        if self.started {
            return Task::ready(Ok(()));
        }
        let (opened, receiver) = async_channel::bounded::<()>(1);
        self.waiters.push(opened);
        let (outcome, result) = async_channel::bounded::<bool>(2);
        let on_open = outcome.clone();
        executor
            .spawn(async move {
                let _ = on_open.try_send(receiver.recv().await.is_ok());
            })
            .detach();
        let timer = executor.timer(timeout);
        executor
            .spawn(async move {
                timer.await;
                let _ = outcome.try_send(false);
            })
            .detach();
        executor.spawn(async move {
            match result.recv().await {
                Ok(true) => Ok(()),
                _ => Err(PAGE_NOT_STARTED_MESSAGE.to_string()),
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::TestAppContext;

    #[gpui::test]
    async fn scripts_wait_for_the_first_page_load_to_start(cx: &mut TestAppContext) {
        let mut gate = PageGate::default();
        let waiting = gate.wait(&cx.executor(), PAGE_START_TIMEOUT);
        cx.run_until_parked();
        gate.open();
        assert_eq!(waiting.await, Ok(()));
        assert!(gate.is_open());
    }

    #[gpui::test]
    async fn an_open_gate_lets_scripts_through_at_once(cx: &mut TestAppContext) {
        let mut gate = PageGate::default();
        gate.open();
        assert_eq!(gate.wait(&cx.executor(), PAGE_START_TIMEOUT).await, Ok(()));
    }

    #[gpui::test]
    async fn a_script_that_waited_too_long_fails_and_stays_failed(cx: &mut TestAppContext) {
        let mut gate = PageGate::default();
        let waiting = gate.wait(&cx.executor(), PAGE_START_TIMEOUT);
        cx.executor().advance_clock(PAGE_START_TIMEOUT);
        assert_eq!(waiting.await, Err(PAGE_NOT_STARTED_MESSAGE.to_string()));
        // Opening later must not revive it.
        gate.open();
        cx.run_until_parked();
    }

    #[gpui::test]
    async fn dropping_the_gate_fails_its_waiters(cx: &mut TestAppContext) {
        let mut gate = PageGate::default();
        let waiting = gate.wait(&cx.executor(), PAGE_START_TIMEOUT);
        drop(gate);
        assert_eq!(waiting.await, Err(PAGE_NOT_STARTED_MESSAGE.to_string()));
    }
}
