//! Mac-side control for the identical uncredentialed probe used by the phone.
//! No pairing, accessibility queries, capture, or input commands.
use std::ffi::{CStr, CString};

fn main() {
    let address = std::env::args().nth(1).expect("Usage: transport_probe IP");
    let host = CString::new(address.clone()).expect("Invalid address");
    for port in [49152u16, 62078] {
        let pointer = unsafe { phone_history_core::phone_history_transport_probe(host.as_ptr(), port) };
        assert!(!pointer.is_null());
        let text = unsafe { CStr::from_ptr(pointer).to_str().expect("Invalid result").to_owned() };
        unsafe { phone_history_core::phone_history_free(pointer) };
        let report: serde_json::Value = serde_json::from_str(&text).expect("Invalid report");
        println!("{}", serde_json::json!({"address":address,"port":port,"report":report}));
    }
}
