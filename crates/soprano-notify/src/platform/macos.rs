//! macOS: `UNUserNotificationCenter`.
//!
//! UserNotifications requires a Launch Services application bundle. A `cargo run` binary has
//! none, and `UNUserNotificationCenter.currentNotificationCenter` raises an Objective-C
//! exception in that state, so unbundled runs get no backend (banners silently off,
//! authorization `unavailable`).

use std::ptr::NonNull;
use std::sync::{Arc, Mutex};

use block2::RcBlock;
use objc2::rc::Retained;
use objc2::runtime::{AnyObject, Bool, NSObject, NSObjectProtocol, ProtocolObject};
use objc2::{AllocAnyThread, DefinedClass, define_class, msg_send};
use objc2_foundation::{NSArray, NSBundle, NSDictionary, NSError, NSString};
use objc2_user_notifications::{
    UNAuthorizationOptions, UNAuthorizationStatus, UNMutableNotificationContent, UNNotification,
    UNNotificationPresentationOptions, UNNotificationRequest, UNNotificationResponse, UNNotificationSettings,
    UNNotificationSound, UNUserNotificationCenter, UNUserNotificationCenterDelegate,
};
use soprano_platform::AppIdentity;

use super::{Banner, BannerClick, ClickHandler, NotificationBackend, SystemAuthorization};

pub(crate) fn backend(
    _identity: &AppIdentity,
    on_click: ClickHandler,
) -> Option<Arc<dyn NotificationBackend>> {
    if !is_bundled_app() {
        return None;
    }
    let delegate = Delegate::new(on_click);
    center().setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
    Some(Arc::new(MacBackend { _delegate: delegate }))
}

fn is_bundled_app() -> bool {
    let bundle = NSBundle::mainBundle();
    let is_app = bundle.bundleURL().pathExtension().is_some_and(|extension| extension.to_string() == "app");
    is_app && bundle.bundleIdentifier().is_some()
}

fn center() -> Retained<UNUserNotificationCenter> {
    UNUserNotificationCenter::currentNotificationCenter()
}

/// Objective-C completion blocks are `Fn`; each is called once.
fn once<A: 'static>(done: Box<dyn FnOnce(A) + Send>) -> impl Fn(A) + 'static {
    let done = Mutex::new(Some(done));
    move |value| {
        if let Some(done) = done.lock().expect("completion lock").take() {
            done(value);
        }
    }
}

struct MacBackend {
    /// The center holds its delegate weakly.
    _delegate: Retained<Delegate>,
}

// SAFETY: the delegate is immutable after creation, its only ivar is `Send + Sync`, and
// retain/release of an `NSObject` is thread-safe.
unsafe impl Send for MacBackend {}
unsafe impl Sync for MacBackend {}

impl NotificationBackend for MacBackend {
    fn authorization_status(&self, done: Box<dyn FnOnce(SystemAuthorization) + Send>) {
        let done = once(done);
        let block = RcBlock::new(move |settings: NonNull<UNNotificationSettings>| {
            // SAFETY: the system passes a valid settings object for the call's duration.
            let status = unsafe { settings.as_ref() }.authorizationStatus();
            done(system_authorization(status));
        });
        center().getNotificationSettingsWithCompletionHandler(&block);
    }

    fn request_authorization(&self, done: Box<dyn FnOnce(bool) + Send>) {
        let done = once(done);
        let block = RcBlock::new(move |granted: Bool, _error: *mut NSError| done(granted.as_bool()));
        center().requestAuthorizationWithOptions_completionHandler(
            UNAuthorizationOptions::Alert | UNAuthorizationOptions::Sound,
            &block,
        );
    }

    fn post(&self, banner: Banner, done: Box<dyn FnOnce(Result<(), String>) + Send>) {
        let content = UNMutableNotificationContent::new();
        content.setTitle(&NSString::from_str(&banner.title));
        content.setBody(&NSString::from_str(&banner.body));
        if let Some(subtitle) = &banner.subtitle {
            content.setSubtitle(&NSString::from_str(subtitle));
        }
        if banner.plays_sound {
            content.setSound(Some(&UNNotificationSound::defaultSound()));
        }
        content.setThreadIdentifier(&NSString::from_str(&banner.thread_identifier));
        let mut entries =
            vec![("paneId", banner.target.pane_id.as_str()), ("tabId", banner.target.tab_id.as_str())];
        if let Some(run_id) = &banner.automation_run_id {
            entries.push(("automationRunId", run_id));
        }
        let keys: Vec<Retained<NSString>> = entries.iter().map(|(key, _)| NSString::from_str(key)).collect();
        let values: Vec<Retained<NSString>> =
            entries.iter().map(|(_, value)| NSString::from_str(value)).collect();
        let user_info = NSDictionary::<NSString, NSString>::from_slices(
            &keys.iter().map(|key| &**key).collect::<Vec<_>>(),
            &values.iter().map(|value| &**value).collect::<Vec<_>>(),
        );
        // SAFETY: an `NSDictionary` of strings is a valid property-list user info dictionary.
        unsafe { content.setUserInfo(user_info.cast_unchecked::<AnyObject, AnyObject>()) };

        // One banner per tab: the next one replaces it instead of stacking a history of every
        // turn in Notification Center.
        let request = UNNotificationRequest::requestWithIdentifier_content_trigger(
            &NSString::from_str(&banner.identifier),
            &content,
            None,
        );
        let done = once(done);
        let block = RcBlock::new(move |error: *mut NSError| {
            // SAFETY: the system passes either null or a valid error.
            let result = match unsafe { error.as_ref() } {
                Some(error) => Err(error.localizedDescription().to_string()),
                None => Ok(()),
            };
            done(result);
        });
        center().addNotificationRequest_withCompletionHandler(&request, Some(&block));
    }

    fn remove_delivered(&self, identifiers: &[String]) {
        let identifiers: Vec<Retained<NSString>> =
            identifiers.iter().map(|id| NSString::from_str(id)).collect();
        let array = NSArray::from_retained_slice(&identifiers);
        center().removeDeliveredNotificationsWithIdentifiers(&array);
    }
}

fn system_authorization(status: UNAuthorizationStatus) -> SystemAuthorization {
    if status == UNAuthorizationStatus::Authorized
        || status == UNAuthorizationStatus::Provisional
        || status == UNAuthorizationStatus::Ephemeral
    {
        SystemAuthorization::Authorized
    } else if status == UNAuthorizationStatus::Denied {
        SystemAuthorization::Denied
    } else if status == UNAuthorizationStatus::NotDetermined {
        SystemAuthorization::NotDetermined
    } else {
        SystemAuthorization::Unknown
    }
}

struct DelegateIvars {
    on_click: ClickHandler,
}

define_class!(
    #[unsafe(super(NSObject))]
    #[name = "SopranoNotificationCenterDelegate"]
    #[ivars = DelegateIvars]
    struct Delegate;

    unsafe impl NSObjectProtocol for Delegate {}

    unsafe impl UNUserNotificationCenterDelegate for Delegate {
        /// Banners show while the app is frontmost too: they are only posted for panes that
        /// are not focused.
        #[unsafe(method(userNotificationCenter:willPresentNotification:withCompletionHandler:))]
        fn will_present(
            &self,
            _center: &UNUserNotificationCenter,
            _notification: &UNNotification,
            completion_handler: &block2::DynBlock<dyn Fn(UNNotificationPresentationOptions)>,
        ) {
            completion_handler.call((
                UNNotificationPresentationOptions::Banner | UNNotificationPresentationOptions::Sound,
            ));
        }

        #[unsafe(method(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:))]
        fn did_receive(
            &self,
            _center: &UNUserNotificationCenter,
            response: &UNNotificationResponse,
            completion_handler: &block2::DynBlock<dyn Fn()>,
        ) {
            let info = response.notification().request().content().userInfo();
            let value = |key: &str| -> Option<String> {
                let object = info.objectForKey(&NSString::from_str(key))?;
                object.downcast::<NSString>().ok().map(|string| string.to_string())
            };
            if let Some(click) = BannerClick::from_user_info(
                value("paneId").as_deref(),
                value("tabId").as_deref(),
                value("automationRunId").as_deref(),
            ) {
                (self.ivars().on_click)(click);
            }
            completion_handler.call(());
        }
    }
);

impl Delegate {
    fn new(on_click: ClickHandler) -> Retained<Self> {
        let this = Self::alloc().set_ivars(DelegateIvars { on_click });
        // SAFETY: `NSObject`'s designated initializer.
        unsafe { msg_send![super(this), init] }
    }
}
