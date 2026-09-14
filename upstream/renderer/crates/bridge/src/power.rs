use std::{
    ffi::c_void,
    marker::PhantomData,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
};

use objc2_core_foundation::{CFRetained, CFRunLoop, CFString, CFType, kCFRunLoopDefaultMode};
use objc2_io_kit::{
    IOPSCopyPowerSourcesInfo, IOPSGetProvidingPowerSourceType, IOPSNotificationCreateRunLoopSource,
    kIOPMACPowerKey, kIOPMBatteryPowerKey, kIOPMUPSPowerKey,
};

use crate::{
    actor::{BridgeActorHandle, messages::SetPowerSource},
    engine::EngineFacade,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PowerSource {
    External,
    Battery,
    Unknown,
}

#[derive(Debug)]
pub(crate) struct PowerWatcher<E: EngineFacade> {
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
    engine: PhantomData<E>,
}

impl<E: EngineFacade + Clone> PowerWatcher<E> {
    #[allow(clippy::single_call_fn)]
    pub(crate) fn spawn(actor: BridgeActorHandle<E>) -> Self {
        let current_source = SystemPowerSource::current();

        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = Arc::clone(&stop);
        let worker = thread::Builder::new()
            .name("wallpaper-bridge-power-watcher".to_string())
            .spawn(move || {
                PowerEventLoop {
                    context: Box::new(PowerNotificationContext {
                        actor,
                        stop: worker_stop,
                        current: current_source,
                    }),
                }
                .run();
            })
            .ok();

        Self {
            stop,
            worker,
            engine: PhantomData,
        }
    }
}

impl<E: EngineFacade> Drop for PowerWatcher<E> {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[derive(Debug)]
pub(crate) struct SystemPowerSource;

impl SystemPowerSource {
    pub(crate) fn current() -> PowerSource {
        IOPSCopyPowerSourcesInfo()
            .map(|snapshot| PowerSourceSnapshot { snapshot })
            .map_or(PowerSource::Unknown, |snapshot| snapshot.current())
    }
}

#[derive(Debug)]
struct PowerSourceSnapshot {
    snapshot: CFRetained<CFType>,
}

impl PowerSourceSnapshot {
    fn current(&self) -> PowerSource {
        let Some(source) = self.providing_source_type() else {
            return PowerSource::Unknown;
        };
        PowerSource::from(source.as_ref())
    }

    fn providing_source_type(&self) -> Option<CFRetained<CFString>> {
        // SAFETY: `snapshot` is the opaque value returned by
        // `IOPSCopyPowerSourcesInfo`, which is exactly the input contract for
        // `IOPSGetProvidingPowerSourceType`.
        unsafe { IOPSGetProvidingPowerSourceType(Some(&self.snapshot)) }
    }
}

impl From<&CFString> for PowerSource {
    fn from(source: &CFString) -> Self {
        if Self::source_matches(source, kIOPMACPowerKey) {
            Self::External
        } else if Self::source_matches(source, kIOPMBatteryPowerKey)
            || Self::source_matches(source, kIOPMUPSPowerKey)
        {
            Self::Battery
        } else {
            Self::Unknown
        }
    }
}

impl PowerSource {
    fn source_matches(source: &CFString, expected: &std::ffi::CStr) -> bool {
        let expected = CFString::from_str(
            expected
                .to_str()
                .expect("IOKit power source constants are valid UTF-8"),
        );
        source == expected.as_ref()
    }
}

struct PowerEventLoop<E: EngineFacade> {
    context: Box<PowerNotificationContext<E>>,
}

impl<E: EngineFacade + Clone> PowerEventLoop<E> {
    fn run(mut self) {
        let Some(run_loop) = CFRunLoop::current() else {
            log::debug!("power source watcher skipped: current run loop unavailable");
            return;
        };
        // SAFETY: CoreFoundation exposes this immutable process-wide constant.
        let Some(mode) = (unsafe { kCFRunLoopDefaultMode }) else {
            log::debug!("power source watcher skipped: default run loop mode unavailable");
            return;
        };

        let source = self.context.create_run_loop_source();
        let Some(source) = source else {
            log::debug!("power source watcher skipped: IOKit notification source unavailable");
            return;
        };

        run_loop.add_source(Some(&source), Some(mode));
        while !self.context.should_stop() {
            CFRunLoop::run_in_mode(Some(mode), 5.0, true);
        }
        run_loop.remove_source(Some(&source), Some(mode));
        source.invalidate();
    }
}

struct PowerNotificationContext<E: EngineFacade> {
    actor: BridgeActorHandle<E>,
    stop: Arc<AtomicBool>,
    current: PowerSource,
}

impl<E: EngineFacade + Clone> PowerNotificationContext<E> {
    fn should_stop(&self) -> bool {
        self.stop.load(Ordering::Relaxed)
    }

    fn create_run_loop_source(
        &mut self,
    ) -> Option<CFRetained<objc2_core_foundation::CFRunLoopSource>> {
        let context = std::ptr::from_mut(self).cast::<c_void>();
        // SAFETY: `context` points to the boxed `PowerNotificationContext` owned by
        // `PowerEventLoop::run`. That box outlives the run-loop source and is not moved
        // while callbacks may fire. The callback casts it back to the same type.
        unsafe { IOPSNotificationCreateRunLoopSource(Some(handle_power_change::<E>), context) }
    }

    fn handle_power_change_event(&mut self) {
        let next = SystemPowerSource::current();
        if next == self.current {
            return;
        }
        self.current = next;
        if let Err(error) = self.actor.blocking_ask(SetPowerSource {
            source: next,
            initial_sample: false,
        }) {
            log::debug!("power source update skipped: {error}");
        }
    }
}

/// Receives `IOKit` power-source change callbacks for [`PowerWatcher`].
///
/// # Safety
///
/// `context` must be the pointer created by
/// [`PowerNotificationContext::create_run_loop_source`] for the same `E`.
pub unsafe extern "C-unwind" fn handle_power_change<E: EngineFacade + Clone>(context: *mut c_void) {
    // SAFETY: The run-loop source was created with a pointer to a live
    // `PowerNotificationContext<E>`, and `PowerEventLoop::run` keeps that box
    // pinned in place until after the source is removed and invalidated.
    let Some(context) = (unsafe { context.cast::<PowerNotificationContext<E>>().as_mut() }) else {
        return;
    };
    context.handle_power_change_event();
}

#[cfg(test)]
mod tests {
    use objc2_core_foundation::CFString;
    use objc2_io_kit::{kIOPMACPowerKey, kIOPMBatteryPowerKey, kIOPMUPSPowerKey};

    use super::PowerSource;

    #[test]
    fn power_source_classifier_maps_ac_to_external_power() {
        let source = TestPowerSource::from_iokit_constant(kIOPMACPowerKey);

        assert_eq!(PowerSource::from(source.as_ref()), PowerSource::External);
    }

    #[test]
    fn power_source_classifier_maps_battery_and_ups_to_battery_power() {
        let battery = TestPowerSource::from_iokit_constant(kIOPMBatteryPowerKey);
        let ups = TestPowerSource::from_iokit_constant(kIOPMUPSPowerKey);

        assert_eq!(PowerSource::from(battery.as_ref()), PowerSource::Battery);
        assert_eq!(PowerSource::from(ups.as_ref()), PowerSource::Battery);
    }

    #[test]
    fn power_source_classifier_preserves_unknown_source() {
        let source = CFString::from_static_str("unexpected source");

        assert_eq!(PowerSource::from(source.as_ref()), PowerSource::Unknown);
    }

    struct TestPowerSource;

    impl TestPowerSource {
        fn from_iokit_constant(
            value: &'static std::ffi::CStr,
        ) -> objc2_core_foundation::CFRetained<CFString> {
            CFString::from_str(value.to_str().expect("IOKit constants are UTF-8"))
        }
    }
}
