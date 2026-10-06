use std::ffi::{CStr,CString};
fn main() {
    let path = CString::new(std::env::args().nth(1).expect("Usage: listener_probe PRIVATE_CONFIG")).unwrap();
    let pointer = unsafe { phone_history_core::phone_history_listener_probe(path.as_ptr()) };
    assert!(!pointer.is_null());
    println!("{}",unsafe { CStr::from_ptr(pointer).to_str().unwrap() });
    unsafe { phone_history_core::phone_history_free(pointer) };
}
