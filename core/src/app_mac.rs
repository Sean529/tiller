//! The `NSApplication` subclass CEF requires on macOS. It has to be the shared
//! application before AppKit is touched anywhere else, so `tiller_core_start`
//! installs it first thing.

use cef::application_mac::{CefAppProtocol, CrAppControlProtocol, CrAppProtocol};
use objc2::{
    ClassType, DefinedClass, MainThreadMarker, define_class, extern_methods, msg_send,
    rc::Retained,
    runtime::{AnyObject, Bool, NSObjectProtocol},
};
use objc2_app_kit::{NSApp, NSApplication, NSEvent};
use std::cell::Cell;

thread_local! {
    /// Run by `terminate:` in place of closing every browser. It closes the
    /// app's tabs, those without a browser included.
    static QUIT_HANDLER: Cell<Option<unsafe extern "C" fn()>> = const { Cell::new(None) };
}

/// Sets the function run when the app is asked to quit. `None` clears it.
pub fn set_quit_handler(handler: Option<unsafe extern "C" fn()>) {
    QUIT_HANDLER.set(handler);
}

#[derive(Default)]
pub struct TillerApplicationIvars {
    handling_send_event: Cell<Bool>,
}

define_class!(
    #[unsafe(super(NSApplication))]
    #[name = "TillerApplication"]
    #[ivars = TillerApplicationIvars]
    pub struct TillerApplication;

    impl TillerApplication {
        #[unsafe(method(sendEvent:))]
        unsafe fn send_event(&self, event: &NSEvent) {
            let was_sending = self.ivars().handling_send_event.get().as_bool();
            if !was_sending {
                self.ivars().handling_send_event.set(Bool::YES);
            }
            let _: () = unsafe { msg_send![super(self), sendEvent: event] };
            if !was_sending {
                self.ivars().handling_send_event.set(Bool::NO);
            }
        }

        /// Chromium needs to leave the run loop to shut down cleanly, so the
        /// default `terminate:` (which calls exit()) is replaced by closing every
        /// browser. The quit handler does that when the app set one, since it
        /// knows about tabs that have no browser yet. The last `on_before_close`
        /// quits the message loop.
        #[unsafe(method(terminate:))]
        unsafe fn terminate(&self, _sender: Option<&AnyObject>) {
            match QUIT_HANDLER.get() {
                Some(handler) => unsafe { handler() },
                None => crate::browser::close_all(),
            }
        }
    }

    unsafe impl CrAppControlProtocol for TillerApplication {
        #[unsafe(method(setHandlingSendEvent:))]
        unsafe fn set_handling_send_event(&self, handling: Bool) {
            self.ivars().handling_send_event.set(handling);
        }
    }

    unsafe impl CrAppProtocol for TillerApplication {
        #[unsafe(method(isHandlingSendEvent))]
        unsafe fn is_handling_send_event(&self) -> Bool {
            self.ivars().handling_send_event.get()
        }
    }

    unsafe impl CefAppProtocol for TillerApplication {}
);

impl TillerApplication {
    extern_methods! {
        #[unsafe(method(sharedApplication))]
        fn shared_application() -> Retained<Self>;
    }
}

/// Makes `TillerApplication` the shared application. Returns false if something
/// already created a plain `NSApplication`.
pub fn install() -> bool {
    let Some(mtm) = MainThreadMarker::new() else {
        return false;
    };
    let _ = TillerApplication::shared_application();
    NSApp(mtm).isKindOfClass(TillerApplication::class())
}
