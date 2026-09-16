use std::sync::{Arc, Mutex};

use super::{DisplaySnapshotEntry, PointerConsumerCallback};
use crate::window::MouseButtonTracker;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct EngineSnapshot {
    pub displays: Vec<DisplaySnapshotEntry>,
}

impl EngineSnapshot {
    pub fn has_pointer_consumers(&self) -> bool {
        self.displays.iter().any(|entry| entry.handle.is_some() && entry.accepts_pointer_input)
    }
}

struct PointerConsumerObserver {
    callback: Option<PointerConsumerCallback>,
    has_consumers: bool,
}

pub struct EngineSnapshotPublisher {
    snapshot: arc_swap::ArcSwap<EngineSnapshot>,
    pointer_consumer: Mutex<PointerConsumerObserver>,
    mouse_buttons: Arc<Mutex<MouseButtonTracker>>,
}

impl EngineSnapshotPublisher {
    pub fn new(snapshot: EngineSnapshot, mouse_buttons: Arc<Mutex<MouseButtonTracker>>) -> Self {
        let has_consumers = snapshot.has_pointer_consumers();
        Self {
            snapshot: arc_swap::ArcSwap::from_pointee(snapshot),
            pointer_consumer: Mutex::new(PointerConsumerObserver { callback: None, has_consumers }),
            mouse_buttons,
        }
    }

    pub fn load(&self) -> Arc<EngineSnapshot> { self.snapshot.load_full() }

    /// Callbacks run synchronously under the observer lock and must only update
    /// polling control. They must not call back into the engine or panic.
    pub fn set_pointer_consumer_callback(&self, callback: Option<PointerConsumerCallback>) {
        let mut observer = self.pointer_consumer.lock().unwrap_or_else(|error| error.into_inner());
        observer.callback = callback;
        if let Some(callback) = &observer.callback { callback(observer.has_consumers); }
    }

    pub fn publish(&self, snapshot: EngineSnapshot) {
        let has_consumers = snapshot.has_pointer_consumers();
        let snapshot = Arc::new(snapshot);
        let mut observer = self.pointer_consumer.lock().unwrap_or_else(|error| error.into_inner());
        let changed = observer.has_consumers != has_consumers;
        if has_consumers && !observer.has_consumers {
            // Serialize activation with OS events and samples; preserve held levels.
            let mut tracker = self.mouse_buttons.lock().unwrap_or_else(|error| error.into_inner());
            let _ = tracker.consume_edges();
            self.snapshot.store(snapshot);
            observer.has_consumers = has_consumers;
            drop(tracker);
        } else {
            self.snapshot.store(snapshot);
            observer.has_consumers = has_consumers;
        }
        if changed {
            if let Some(callback) = &observer.callback { callback(has_consumers); }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{DisplayDesc, DisplayIdentity};

    fn interactive_snapshot() -> EngineSnapshot {
        EngineSnapshot { displays: vec![DisplaySnapshotEntry {
            identity: DisplayIdentity::default(),
            desc: DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            handle: Some(crate::project::SceneHandle::new(1)),
            accepts_pointer_input: true,
            window_active: true,
            assignment: None,
        }] }
    }

    #[test]
    fn activation_discards_old_edges_preserves_held_levels_and_new_taps() {
        let tracker = Arc::new(Mutex::new(MouseButtonTracker::new()));
        let publisher = EngineSnapshotPublisher::new(EngineSnapshot::default(), tracker.clone());
        {
            let mut tracker = tracker.lock().unwrap();
            tracker.set_button(0, true);
            tracker.set_button(0, false);
            tracker.set_button(1, true);
        }
        publisher.publish(interactive_snapshot());
        {
            let mut tracker = tracker.lock().unwrap();
            let held = tracker.consume_edges();
            assert_eq!(held.down().mask(), 2);
            assert!(held.transitions().next().is_none());
            tracker.set_button(1, false);
            tracker.set_button(2, true);
            tracker.set_button(2, false);
        }
        // Neither observer replay nor a true -> true commit clears active edges.
        let replay = Arc::new(Mutex::new(Vec::new()));
        publisher.set_pointer_consumer_callback(Some(Arc::new({
            let replay = replay.clone();
            move |value| replay.lock().unwrap().push(value)
        })));
        publisher.publish(interactive_snapshot());
        let edges: Vec<_> = tracker.lock().unwrap().consume_edges().transitions()
            .map(|edge| (edge.button, edge.pressed)).collect();
        assert_eq!(edges, vec![(1, false), (2, true), (2, false)]);
        assert_eq!(*replay.lock().unwrap(), vec![true]);
    }

    #[test]
    fn activation_waits_for_tracker_before_publishing() {
        let tracker = Arc::new(Mutex::new(MouseButtonTracker::new()));
        let publisher = Arc::new(EngineSnapshotPublisher::new(EngineSnapshot::default(), tracker.clone()));
        let mut held = tracker.lock().unwrap();
        held.set_button(0, true);
        held.set_button(0, false);
        let started = Arc::new(std::sync::Barrier::new(2));
        let writer = std::thread::spawn({
            let publisher = publisher.clone();
            let started = started.clone();
            move || {
                started.wait();
                publisher.publish(interactive_snapshot());
            }
        });
        started.wait();
        assert!(!publisher.load().has_pointer_consumers());
        drop(held);
        writer.join().unwrap();
        assert!(publisher.load().has_pointer_consumers());
        assert!(tracker.lock().unwrap().consume_edges().transitions().next().is_none());
    }

    #[test]
    fn registration_replay_serializes_before_publication() {
        let tracker = Arc::new(Mutex::new(MouseButtonTracker::new()));
        let publisher = Arc::new(EngineSnapshotPublisher::new(EngineSnapshot::default(), tracker));
        let (seen_tx, seen_rx) = std::sync::mpsc::channel();
        let release = Arc::new(std::sync::Barrier::new(2));
        let register = std::thread::spawn({
            let publisher = publisher.clone();
            let release = release.clone();
            move || publisher.set_pointer_consumer_callback(Some(Arc::new(move |value| {
                seen_tx.send(value).unwrap();
                if !value { release.wait(); }
            })))
        });
        assert!(!seen_rx.recv().unwrap());
        let writer = std::thread::spawn({
            let publisher = publisher.clone();
            move || publisher.publish(interactive_snapshot())
        });
        release.wait();
        register.join().unwrap();
        writer.join().unwrap();
        assert!(seen_rx.recv().unwrap());
        publisher.set_pointer_consumer_callback(None);
    }

    #[test]
    fn publication_serializes_before_replacement_replay() {
        let tracker = Arc::new(Mutex::new(MouseButtonTracker::new()));
        let publisher = Arc::new(EngineSnapshotPublisher::new(EngineSnapshot::default(), tracker));
        let (committed_tx, committed_rx) = std::sync::mpsc::channel();
        let release = Arc::new(std::sync::Barrier::new(2));
        publisher.set_pointer_consumer_callback(Some(Arc::new({
            let release = release.clone();
            move |value| if value { committed_tx.send(()).unwrap(); release.wait(); }
        })));
        let writer = std::thread::spawn({
            let publisher = publisher.clone();
            move || publisher.publish(interactive_snapshot())
        });
        committed_rx.recv().unwrap();
        let (replay_tx, replay_rx) = std::sync::mpsc::channel();
        let register = std::thread::spawn({
            let publisher = publisher.clone();
            move || publisher.set_pointer_consumer_callback(Some(Arc::new(move |value| {
                replay_tx.send(value).unwrap();
            })))
        });
        release.wait();
        writer.join().unwrap();
        register.join().unwrap();
        assert!(replay_rx.recv().unwrap());
        let mut video = interactive_snapshot();
        video.displays[0].accepts_pointer_input = false;
        publisher.publish(video);
        assert!(!replay_rx.recv().unwrap());
    }

    #[test]
    fn poisoned_tracker_retains_levels_at_activation() {
        let tracker = Arc::new(Mutex::new(MouseButtonTracker::new()));
        let _ = std::thread::spawn({
            let tracker = tracker.clone();
            move || {
                tracker.lock().unwrap().set_button(3, true);
                let _guard = tracker.lock().unwrap();
                panic!("poison tracker");
            }
        }).join();
        let publisher = EngineSnapshotPublisher::new(EngineSnapshot::default(), tracker.clone());
        publisher.publish(interactive_snapshot());
        let edges = tracker.lock().unwrap_or_else(|error| error.into_inner()).consume_edges();
        assert_eq!(edges.down().mask(), 8);
        assert!(edges.transitions().next().is_none());
    }

    #[test]
    fn publisher_returns_initial_snapshot() {
        let publisher = EngineSnapshotPublisher::new(EngineSnapshot::default(), Arc::new(Mutex::new(MouseButtonTracker::new())));

        assert_eq!(publisher.load().displays, Vec::new());
    }

    #[test]
    fn publisher_returns_latest_snapshot() {
        let identity = DisplayIdentity {
            uuid: Some("display-uuid".to_string()),
            vendor_id: Some(10),
            model_id: Some(20),
            serial_number: Some(30),
            unit_number: Some(1),
            name: Some("Studio Display".to_string()),
        };
        let display = DisplayDesc::with_identity(9, identity.clone(), 0, 0, 1920, 1080, 1.0);
        let entry = DisplaySnapshotEntry {
            identity,
            desc: display,
            handle: None,
            accepts_pointer_input: false,
            window_active: true,
            assignment: None,
        };
        let publisher = EngineSnapshotPublisher::new(EngineSnapshot::default(), Arc::new(Mutex::new(MouseButtonTracker::new())));

        publisher.publish(EngineSnapshot {
            displays: vec![entry.clone()],
        });

        assert_eq!(publisher.load().displays, vec![entry]);
    }
}
