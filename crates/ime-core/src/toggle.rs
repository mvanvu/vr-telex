//! Ctrl+Shift tapped alone (D7).
//!
//! The tap fires on the release of the last of Ctrl/Shift when both were
//! down together, in either order, no other key was pressed or released in
//! between, and the chord lasted under a second from its first press.

use std::time::{Duration, Instant};

use crate::key::ChordKey;

const TAP_LIMIT: Duration = Duration::from_secs(1);

/// Holds only which chord keys are down and since when: no key of the user's
/// text ever enters this state (SEC-12).
#[derive(Default)]
pub(crate) struct TapDetector {
    down: u8,
    both_seen: bool,
    spoiled: bool,
    started: Option<Instant>,
}

impl TapDetector {
    pub(crate) fn reset(&mut self) {
        *self = Self::default();
    }

    /// Something that is not part of a clean tap happened: another key, a
    /// click. Matters only while a chord is in progress.
    pub(crate) fn spoil(&mut self) {
        if self.down != 0 {
            self.spoiled = true;
        }
    }

    /// Feeds a press or release of Ctrl or Shift. `foreign` tells that Alt,
    /// Super or the like is held. Returns true when the tap completes.
    pub(crate) fn chord_key(
        &mut self,
        key: ChordKey,
        release: bool,
        foreign: bool,
        now: Instant,
    ) -> bool {
        if !release {
            if self.down == 0 {
                self.reset();
                self.started = Some(now);
            }
            // Auto-repeat presses of a held key change nothing.
            self.down |= key.0;
            self.spoiled |= foreign;
            if self.down & ChordKey::CTRL != 0 && self.down & ChordKey::SHIFT != 0 {
                self.both_seen = true;
            }
            return false;
        }
        // The press was never seen (it went to another context): not a tap.
        if self.down & key.0 == 0 {
            return false;
        }
        self.down &= !key.0;
        self.spoiled |= foreign;
        if self.down != 0 {
            return false;
        }
        let quick = self
            .started
            .is_some_and(|at| now.saturating_duration_since(at) < TAP_LIMIT);
        let fired = self.both_seen && !self.spoiled && quick;
        self.reset();
        fired
    }
}
