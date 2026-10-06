//! Sampling policy, independent of app names and page content.
use std::time::Duration;

pub const MAX_HIERARCHY_READS: usize = 32;
pub const MAX_DESCENT_MILLIS: u64 = 700;
pub const DEEP_REFRESH: Duration = Duration::from_secs(30);

pub fn expand_role(role: &str) -> bool {
    // A role/description does not establish leafhood. Even a Button handle
    // returned at the root can lead to the page's semantic descendants.
    // Expand distinct handles within the shared walk budget; never descend
    // into editable/secure controls or keyboard content.
    !role.split(',').map(str::trim).any(|r| matches!(r,
        "TextField"|"SearchField"|"SecureTextField"|"KeyboardKey"))
}
pub fn heading(role: &str, description: &str) -> bool {
    role.split(',').map(str::trim).any(|r|matches!(r,"Header"|"Heading")) ||
    description.ends_with(", Header") || description.ends_with(" Header") ||
    description.ends_with(", Heading") || description.ends_with(" Heading")
}
pub fn cadence(unchanged: u32) -> Duration {
    Duration::from_secs(match unchanged { 0=>3, 1=>5, 2..=4=>12, _=>20 })
}
pub fn visual_cadence(unchanged:u32)->Duration { Duration::from_secs(match unchanged {0=>10,1..=3=>20,_=>30}) }
#[derive(Default)]
pub struct Retry { failures: u32 }
impl Retry {
    pub fn healthy(&mut self, successful: u32, elapsed: Duration) {
        // A TCP connection alone is not recovery; a healthy reader must last.
        if successful>=3 && elapsed>=Duration::from_secs(60) { self.failures=0; }
    }
    pub fn delay(&mut self)->Duration {
        let seconds=(4u64 << self.failures.min(4)).min(60);
        self.failures=self.failures.saturating_add(1);
        Duration::from_secs(seconds)
    }
}
#[cfg(test)] mod tests {
 use super::*;
 #[test] fn roles_do_not_assert_leafhood_and_editable_fields_are_not_expanded() {
   assert!(expand_role("Static Text")); assert!(expand_role("Button, Toggle"));
   assert!(expand_role("Link")); assert!(expand_role("")); assert!(expand_role("WebArea"));
   assert!(!expand_role("SecureTextField")); assert!(!expand_role("TextField"));
 }
 #[test] fn connection_churn_cannot_reset_backoff_before_reader_is_healthy() {
   let mut retry=Retry::default();
   assert_eq!(retry.delay().as_secs(),4);
   retry.healthy(100,Duration::from_secs(5));assert_eq!(retry.delay().as_secs(),8);
   retry.healthy(1,Duration::from_secs(100));assert_eq!(retry.delay().as_secs(),16);
   retry.healthy(3,Duration::from_secs(60));assert_eq!(retry.delay().as_secs(),4);
   for _ in 0..20 { assert!(retry.delay().as_secs()<=60); }
 }
 #[test] fn visual_sampling_is_bounded_and_adapts_to_idle_screens() {
   assert_eq!(visual_cadence(0).as_secs(),10);assert_eq!(visual_cadence(1).as_secs(),20);
   assert_eq!(visual_cadence(100).as_secs(),30);
 }
 #[test] fn quiet_screens_slow_down_without_turning_off_capture() {
   assert_eq!(cadence(0).as_secs(),3); assert_eq!(cadence(2).as_secs(),12);
   assert_eq!(cadence(10).as_secs(),20);
 }
}
