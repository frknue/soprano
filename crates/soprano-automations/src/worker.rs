//! The one background thread runs are prepared and wrapped up on (prechecks, worktrees, trust,
//! transcript reads). Serial, so a worktree is removed only after the work queued before it.
//! Results wait in a channel until the host drains them on its own thread.

use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;

pub(crate) type Job<T> = Box<dyn FnOnce() -> Option<T> + Send>;

pub(crate) struct Worker<T: Send + 'static> {
    jobs: Option<Sender<Job<T>>>,
    /// For jobs run in place when the thread could not start.
    results_sender: Sender<T>,
    results: Receiver<T>,
    wake: Arc<dyn Fn() + Send + Sync>,
}

impl<T: Send + 'static> Worker<T> {
    /// `wake` runs (on the worker thread) after each job that left a result.
    pub fn new(wake: Arc<dyn Fn() + Send + Sync>) -> Self {
        let (jobs, queue) = mpsc::channel::<Job<T>>();
        let (results_sender, results) = mpsc::channel();
        let sender = results_sender.clone();
        let thread_wake = wake.clone();
        let spawned = thread::Builder::new().name("soprano-automations".into()).spawn(move || {
            for job in queue {
                if let Some(result) = job() {
                    if sender.send(result).is_err() {
                        break;
                    }
                    thread_wake();
                }
            }
        });
        if let Err(error) = &spawned {
            tracing::warn!("Soprano: could not start the automations worker: {error}");
        }
        Self { jobs: spawned.is_ok().then_some(jobs), results_sender, results, wake }
    }

    pub fn run(&self, job: impl FnOnce() -> Option<T> + Send + 'static) {
        let job: Job<T> = Box::new(job);
        let job = match &self.jobs {
            Some(jobs) => match jobs.send(job) {
                Ok(()) => return,
                Err(mpsc::SendError(job)) => job,
            },
            None => job,
        };
        // No worker: do the work here rather than lose it.
        if let Some(result) = job() {
            let _ = self.results_sender.send(result);
            (self.wake)();
        }
    }

    /// The next finished result, without waiting.
    pub fn next(&self) -> Option<T> {
        self.results.try_recv().ok()
    }
}
