//! Passive whole-extension CPU accounting; no profiling daemon or extra thread.
use std::time::Instant;
use serde_json::{json,Value};
#[cfg(any(target_os="ios",target_os="macos"))]
fn usage()->Option<(f64,u64)> {
    let mut value=std::mem::MaybeUninit::<libc::rusage>::zeroed();
    if unsafe {libc::getrusage(libc::RUSAGE_SELF,value.as_mut_ptr())} != 0 { return None; }
    let value=unsafe {value.assume_init()};
    let seconds=value.ru_utime.tv_sec as f64+value.ru_stime.tv_sec as f64+
        (value.ru_utime.tv_usec+value.ru_stime.tv_usec) as f64/1_000_000.0;
    // Darwin reports ru_maxrss in bytes. This is peak resident memory,
    // distinct from Instruments' current physical footprint.
    Some((seconds,value.ru_maxrss.max(0) as u64))
}
#[cfg(not(any(target_os="ios",target_os="macos")))] fn usage()->Option<(f64,u64)> {None}
#[cfg(target_os="ios")]
unsafe extern "C" {fn phone_history_native_footprint(peak:libc::c_int)->u64;}
#[cfg(target_os="ios")]
fn footprint()->Option<(u64,u64)> {
 let current=unsafe {phone_history_native_footprint(0)};let peak=unsafe {phone_history_native_footprint(1)};
 if current == 0 {None} else {Some((current,peak))}
}
#[cfg(target_os="macos")]
fn footprint()->Option<(u64,u64)> {
 let mut value=std::mem::MaybeUninit::<libc::rusage_info_v4>::zeroed();
 if unsafe {libc::proc_pid_rusage(libc::getpid(),libc::RUSAGE_INFO_V4,value.as_mut_ptr().cast())} != 0 {return None;}
 let value=unsafe {value.assume_init()};Some((value.ri_phys_footprint,value.ri_lifetime_max_phys_footprint))
}
#[cfg(not(any(target_os="ios",target_os="macos")))] fn footprint()->Option<(u64,u64)> {None}

pub struct Meter {started:Instant,window:Instant,initial:f64,previous:f64}
impl Meter {
 pub fn new()->Self {let cpu=usage().map(|u|u.0).unwrap_or(0.0);Self {started:Instant::now(),window:Instant::now(),initial:cpu,previous:cpu}}
 pub fn sample(&mut self)->Value {
    let Some((cpu,peak))=usage() else {return Value::Null;};
    let elapsed=self.window.elapsed().as_secs_f64().max(0.001);
    let window=if elapsed>=1.0 {Some(100.0*(cpu-self.previous).max(0.0)/elapsed)} else {None};
    let lifetime=100.0*(cpu-self.initial).max(0.0)/self.started.elapsed().as_secs_f64().max(0.001);
    if elapsed>=1.0 {self.previous=cpu;self.window=Instant::now();}
    json!({"cpu_window_percent":window,"window_seconds":elapsed,
        "cpu_since_capture_start_percent":lifetime,"peak_resident_bytes":peak,
        "physical_footprint_bytes":footprint().map(|v|v.0),"peak_physical_footprint_bytes":footprint().map(|v|v.1),
        "scope":"whole_extension_process","source":"getrusage and native task_info","battery_measured":false})
 }
}

// Leave allocation headroom below the tested tunnel's ~50 MiB footprint limit.
pub fn image_budget_available()->bool {footprint().is_none_or(|(current,_)|current<30*1024*1024)}
