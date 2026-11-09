//! Clipboard confirmations (`ClipboardConfirmationCoordinator.swift`): an unsafe paste, or a
//! program reading or writing the clipboard (OSC 52), waits for the user's answer. Requests
//! from every terminal share one first-in, first-out queue so only one prompt shows at a time.
//!
//! The coordinator is single-threaded (the UI thread) and re-entrant: a `resolve` callback may
//! enqueue again, and a request for a terminal being torn down is denied on the spot.

use std::cell::{Cell, RefCell};
use std::collections::{HashSet, VecDeque};
use std::rc::{Rc, Weak};

/// Why the clipboard is involved.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ClipboardConfirmationKind {
    /// Pasting text that could run commands.
    Paste,
    /// A program asks to read the clipboard.
    Osc52Read,
    /// A program asks to write the clipboard.
    Osc52Write,
}

/// What the user is asked, with the content in question.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClipboardConfirmationPrompt {
    pub kind: ClipboardConfirmationKind,
    pub content: String,
}

impl ClipboardConfirmationPrompt {
    pub fn new(kind: ClipboardConfirmationKind, content: impl Into<String>) -> Self {
        Self { kind, content: content.into() }
    }

    pub fn title(&self) -> &'static str {
        match self.kind {
            ClipboardConfirmationKind::Paste => "Warning: Potentially Unsafe Paste",
            ClipboardConfirmationKind::Osc52Read => "Authorize Clipboard Read",
            ClipboardConfirmationKind::Osc52Write => "Authorize Clipboard Write",
        }
    }

    pub fn message(&self) -> &'static str {
        match self.kind {
            ClipboardConfirmationKind::Paste => {
                "Pasting this text to the terminal may be dangerous as it looks like some commands may be executed."
            }
            ClipboardConfirmationKind::Osc52Read => {
                "An application is attempting to read from the clipboard.\nThe current clipboard contents are shown below."
            }
            ClipboardConfirmationKind::Osc52Write => {
                "An application is attempting to write to the clipboard.\nThe content to write is shown below."
            }
        }
    }

    pub fn allow_button_title(&self) -> &'static str {
        match self.kind {
            ClipboardConfirmationKind::Paste => "Paste",
            _ => "Allow",
        }
    }

    pub fn deny_button_title(&self) -> &'static str {
        match self.kind {
            ClipboardConfirmationKind::Paste => "Cancel",
            _ => "Deny",
        }
    }
}

/// How a prompt was answered. Dismissing it (closing the window) denies.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClipboardConfirmationDecision {
    Allow,
    Deny,
    Dismissed,
}

/// A prompt on screen; the coordinator dismisses it when its terminal goes away.
pub trait ClipboardConfirmationPresentation {
    fn dismiss(&self);
}

/// Shows prompts (the app's dialog). `completion` is called once with the answer.
pub trait ClipboardConfirmationPresenter {
    fn present(
        &self,
        prompt: &ClipboardConfirmationPrompt,
        completion: Box<dyn FnOnce(ClipboardConfirmationDecision)>,
    ) -> Box<dyn ClipboardConfirmationPresentation>;
}

/// Identifies the terminal a request belongs to (for example its view's entity id).
pub type SurfaceId = u64;

struct Request {
    id: u64,
    surface: SurfaceId,
    prompt: ClipboardConfirmationPrompt,
    resolve: Box<dyn FnOnce(bool)>,
}

struct ActiveRequest {
    id: u64,
    surface: SurfaceId,
    resolve: Option<Box<dyn FnOnce(bool)>>,
    presentation: Option<Box<dyn ClipboardConfirmationPresentation>>,
}

/// The queue of clipboard confirmations shared by every terminal.
pub struct ClipboardConfirmationCoordinator {
    presenter: Box<dyn ClipboardConfirmationPresenter>,
    queue: RefCell<VecDeque<Request>>,
    active: RefCell<Option<ActiveRequest>>,
    canceling: RefCell<HashSet<SurfaceId>>,
    next_id: Cell<u64>,
    this: Weak<ClipboardConfirmationCoordinator>,
}

impl ClipboardConfirmationCoordinator {
    pub fn new(presenter: impl ClipboardConfirmationPresenter + 'static) -> Rc<Self> {
        Rc::new_cyclic(|this| Self {
            presenter: Box::new(presenter),
            queue: RefCell::new(VecDeque::new()),
            active: RefCell::new(None),
            canceling: RefCell::new(HashSet::new()),
            next_id: Cell::new(0),
            this: this.clone(),
        })
    }

    /// Queues a prompt; `resolve` hears `true` only when the user allowed it.
    pub fn enqueue(
        &self,
        surface: SurfaceId,
        kind: ClipboardConfirmationKind,
        content: impl Into<String>,
        resolve: impl FnOnce(bool) + 'static,
    ) {
        if self.canceling.borrow().contains(&surface) {
            resolve(false);
            return;
        }
        let id = self.next_id.get() + 1;
        self.next_id.set(id);
        self.queue.borrow_mut().push_back(Request {
            id,
            surface,
            prompt: ClipboardConfirmationPrompt::new(kind, content),
            resolve: Box::new(resolve),
        });
        self.present_next_if_needed();
    }

    /// Denies every request of `surface` (its terminal closed), dismissing its prompt.
    pub fn cancel_requests(&self, surface: SurfaceId) {
        if !self.canceling.borrow_mut().insert(surface) {
            return;
        }
        let active = {
            let mut active = self.active.borrow_mut();
            if active.as_ref().is_some_and(|a| a.surface == surface) { active.take() } else { None }
        };
        let queued: Vec<Request> = {
            let mut queue = self.queue.borrow_mut();
            let (matching, rest): (Vec<_>, Vec<_>) = queue.drain(..).partition(|r| r.surface == surface);
            queue.extend(rest);
            matching
        };
        if let Some(mut active) = active {
            if let Some(resolve) = active.resolve.take() {
                resolve(false);
            }
            if let Some(presentation) = active.presentation.take() {
                presentation.dismiss();
            }
        }
        for request in queued {
            (request.resolve)(false);
        }
        self.canceling.borrow_mut().remove(&surface);
        self.present_next_if_needed();
    }

    fn present_next_if_needed(&self) {
        if self.active.borrow().is_some() {
            return;
        }
        let Some(request) = self.queue.borrow_mut().pop_front() else { return };
        let id = request.id;
        *self.active.borrow_mut() = Some(ActiveRequest {
            id,
            surface: request.surface,
            resolve: Some(request.resolve),
            presentation: None,
        });
        let this = self.this.clone();
        let presentation = self.presenter.present(
            &request.prompt,
            Box::new(move |decision| {
                if let Some(this) = this.upgrade() {
                    this.complete(id, decision);
                }
            }),
        );
        let mut active = self.active.borrow_mut();
        match active.as_mut() {
            Some(a) if a.id == id => a.presentation = Some(presentation),
            _ => {}
        }
    }

    fn complete(&self, id: u64, decision: ClipboardConfirmationDecision) {
        let active = {
            let mut active = self.active.borrow_mut();
            if active.as_ref().is_none_or(|a| a.id != id) {
                return;
            }
            active.take()
        };
        if let Some(mut active) = active
            && let Some(resolve) = active.resolve.take()
        {
            resolve(decision == ClipboardConfirmationDecision::Allow);
        }
        self.present_next_if_needed();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct PresentationSpy {
        dismiss_count: Cell<usize>,
    }

    impl ClipboardConfirmationPresentation for Rc<PresentationSpy> {
        fn dismiss(&self) {
            self.dismiss_count.set(self.dismiss_count.get() + 1);
        }
    }

    type Completion = Option<Box<dyn FnOnce(ClipboardConfirmationDecision)>>;
    type Pending = (ClipboardConfirmationPrompt, Completion, Rc<PresentationSpy>);

    #[derive(Clone, Default)]
    struct PresenterSpy {
        pending: Rc<RefCell<Vec<Pending>>>,
    }

    impl PresenterSpy {
        fn prompts(&self) -> Vec<String> {
            self.pending.borrow().iter().map(|p| p.0.content.clone()).collect()
        }

        fn complete(&self, index: usize, decision: ClipboardConfirmationDecision) {
            let completion = self.pending.borrow_mut()[index].1.take();
            if let Some(completion) = completion {
                completion(decision);
            }
        }

        fn dismiss_count(&self, index: usize) -> usize {
            self.pending.borrow()[index].2.dismiss_count.get()
        }
    }

    impl ClipboardConfirmationPresenter for PresenterSpy {
        fn present(
            &self,
            prompt: &ClipboardConfirmationPrompt,
            completion: Box<dyn FnOnce(ClipboardConfirmationDecision)>,
        ) -> Box<dyn ClipboardConfirmationPresentation> {
            let presentation = Rc::new(PresentationSpy::default());
            self.pending.borrow_mut().push((prompt.clone(), Some(completion), presentation.clone()));
            Box::new(presentation)
        }
    }

    fn log() -> Rc<RefCell<Vec<String>>> {
        Rc::new(RefCell::new(Vec::new()))
    }

    fn record(log: &Rc<RefCell<Vec<String>>>, name: &'static str) -> impl FnOnce(bool) + 'static {
        let log = log.clone();
        move |allowed| log.borrow_mut().push(format!("{name}:{allowed}"))
    }

    use ClipboardConfirmationDecision::*;
    use ClipboardConfirmationKind::*;

    #[test]
    fn presents_requests_in_fifo_order() {
        let presenter = PresenterSpy::default();
        let coordinator = ClipboardConfirmationCoordinator::new(presenter.clone());
        let resolutions = log();
        coordinator.enqueue(1, Paste, "first", record(&resolutions, "first"));
        coordinator.enqueue(1, Osc52Read, "second", record(&resolutions, "second"));
        assert_eq!(presenter.prompts(), ["first"]);
        presenter.complete(0, Allow);
        assert_eq!(presenter.prompts(), ["first", "second"]);
        assert_eq!(*resolutions.borrow(), ["first:true"]);
        presenter.complete(1, Deny);
        assert_eq!(*resolutions.borrow(), ["first:true", "second:false"]);
    }

    #[test]
    fn allow_and_deny_resolve_with_their_policy_values() {
        let presenter = PresenterSpy::default();
        let coordinator = ClipboardConfirmationCoordinator::new(presenter.clone());
        let resolutions = log();
        coordinator.enqueue(1, Osc52Read, "read", record(&resolutions, "read"));
        coordinator.enqueue(1, Osc52Write, "write", record(&resolutions, "write"));
        presenter.complete(0, Allow);
        presenter.complete(1, Deny);
        assert_eq!(*resolutions.borrow(), ["read:true", "write:false"]);
    }

    #[test]
    fn dismissal_is_a_denial() {
        let presenter = PresenterSpy::default();
        let coordinator = ClipboardConfirmationCoordinator::new(presenter.clone());
        let resolutions = log();
        coordinator.enqueue(1, Paste, "content", record(&resolutions, "paste"));
        presenter.complete(0, Dismissed);
        assert_eq!(*resolutions.borrow(), ["paste:false"]);
    }

    #[test]
    fn cancellation_denies_only_matching_surface_and_continues_fifo_queue() {
        let presenter = PresenterSpy::default();
        let coordinator = ClipboardConfirmationCoordinator::new(presenter.clone());
        let resolutions = log();
        coordinator.enqueue(1, Paste, "first-active", record(&resolutions, "first-active"));
        coordinator.enqueue(2, Osc52Read, "second", record(&resolutions, "second"));
        coordinator.enqueue(1, Osc52Read, "first-queued", record(&resolutions, "first-queued"));

        coordinator.cancel_requests(1);
        assert_eq!(presenter.dismiss_count(0), 1);
        assert_eq!(presenter.prompts(), ["first-active", "second"]);
        assert_eq!(*resolutions.borrow(), ["first-active:false", "first-queued:false"]);

        presenter.complete(0, Allow);
        assert_eq!(*resolutions.borrow(), ["first-active:false", "first-queued:false"]);
        presenter.complete(1, Allow);
        assert_eq!(*resolutions.borrow(), ["first-active:false", "first-queued:false", "second:true"]);
    }

    #[test]
    fn each_request_resolves_exactly_once() {
        let presenter = PresenterSpy::default();
        let coordinator = ClipboardConfirmationCoordinator::new(presenter.clone());
        let count = Rc::new(Cell::new(0));
        let c = count.clone();
        coordinator.enqueue(1, Osc52Read, "read", move |_| c.set(c.get() + 1));
        presenter.complete(0, Allow);
        presenter.complete(0, Deny);
        coordinator.cancel_requests(1);
        assert_eq!(count.get(), 1);
    }

    #[test]
    fn reentrant_request_for_canceling_surface_is_denied_synchronously() {
        let presenter = PresenterSpy::default();
        let coordinator = ClipboardConfirmationCoordinator::new(presenter.clone());
        let resolutions = log();
        let (inner_log, weak) = (resolutions.clone(), Rc::downgrade(&coordinator));
        coordinator.enqueue(1, Osc52Read, "original", move |allowed| {
            inner_log.borrow_mut().push(format!("original:{allowed}"));
            if let Some(coordinator) = weak.upgrade() {
                coordinator.enqueue(1, Osc52Read, "reentrant", record(&inner_log, "reentrant"));
            }
        });
        coordinator.cancel_requests(1);
        assert_eq!(presenter.prompts(), ["original"]);
        assert_eq!(*resolutions.borrow(), ["original:false", "reentrant:false"]);
    }

    #[test]
    fn request_kinds_have_distinct_native_titles_and_messages() {
        let paste = ClipboardConfirmationPrompt::new(Paste, "");
        let read = ClipboardConfirmationPrompt::new(Osc52Read, "");
        let write = ClipboardConfirmationPrompt::new(Osc52Write, "");
        assert_eq!(paste.title(), "Warning: Potentially Unsafe Paste");
        assert_eq!(
            paste.message(),
            "Pasting this text to the terminal may be dangerous as it looks like some commands may be executed."
        );
        assert_eq!(read.title(), "Authorize Clipboard Read");
        assert_eq!(
            read.message(),
            "An application is attempting to read from the clipboard.\nThe current clipboard contents are shown below."
        );
        assert_eq!(write.title(), "Authorize Clipboard Write");
        assert_eq!(
            write.message(),
            "An application is attempting to write to the clipboard.\nThe content to write is shown below."
        );
        assert_eq!((paste.allow_button_title(), paste.deny_button_title()), ("Paste", "Cancel"));
        assert_eq!((read.allow_button_title(), write.deny_button_title()), ("Allow", "Deny"));
    }
}
