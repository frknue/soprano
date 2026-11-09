//! Every quit asks about unsaved files first (`AppDelegate.applicationShouldTerminate`): ⌘Q
//! and the menu go through `MainView::request_quit`, but on macOS the Dock, logging out and
//! other apps send `terminate:` straight to the app delegate, which GPUI gives no
//! `applicationShouldTerminate:`. This adds one to GPUI's delegate class: with unsaved files
//! it cancels the quit and asks the main view to run the save question (which quits after).
//! Other platforms have no system quit that bypasses the window.

use crate::content::SharedUnsaved;

#[cfg(target_os = "macos")]
mod mac {
    use std::sync::OnceLock;

    use objc2::runtime::{AnyClass, AnyObject, Imp, Sel};
    use objc2::sel;

    use crate::content::SharedUnsaved;

    struct Guard {
        unsaved: SharedUnsaved,
        ask: async_channel::Sender<()>,
    }

    static GUARD: OnceLock<Guard> = OnceLock::new();

    /// `NSApplicationTerminateReply`: cancel, now.
    const TERMINATE_CANCEL: usize = 0;
    const TERMINATE_NOW: usize = 1;

    extern "C-unwind" fn should_terminate(_: &AnyObject, _: Sel, _: *mut AnyObject) -> usize {
        let Some(guard) = GUARD.get() else { return TERMINATE_NOW };
        if guard.unsaved.lock().unwrap_or_else(|e| e.into_inner()).has_unsaved() {
            let _ = guard.ask.try_send(());
            TERMINATE_CANCEL
        } else {
            TERMINATE_NOW
        }
    }

    pub fn install(unsaved: SharedUnsaved, ask: async_channel::Sender<()>) {
        if GUARD.set(Guard { unsaved, ask }).is_err() {
            return;
        }
        let Some(class) = AnyClass::get(c"GPUIApplicationDelegate") else {
            tracing::warn!(
                "GPUI's application delegate class is missing; system quits will not ask about unsaved files"
            );
            return;
        };
        let function: extern "C-unwind" fn(&AnyObject, Sel, *mut AnyObject) -> usize = should_terminate;
        // SAFETY: the method has the `applicationShouldTerminate:` signature, `Q@:@` on 64-bit
        // (NSUInteger return, self, _cmd, sender); the class is GPUI's registered delegate.
        unsafe {
            let imp: Imp = std::mem::transmute::<
                extern "C-unwind" fn(&AnyObject, Sel, *mut AnyObject) -> usize,
                Imp,
            >(function);
            objc2::ffi::class_addMethod(
                class as *const AnyClass as *mut AnyClass,
                sel!(applicationShouldTerminate:),
                imp,
                c"Q@:@".as_ptr(),
            );
        }
    }
}

/// Makes system quits ask through `ask` while `unsaved` has unsaved files.
pub fn install(unsaved: SharedUnsaved, ask: async_channel::Sender<()>) {
    #[cfg(target_os = "macos")]
    mac::install(unsaved, ask);
    #[cfg(not(target_os = "macos"))]
    let _ = (unsaved, ask);
}
