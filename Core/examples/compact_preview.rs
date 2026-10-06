#[path = "../src/history.rs"]
mod history;
use std::{collections::BTreeSet,fs};
use serde_json::Value;
fn main() {
    let path=std::env::args().nth(1).expect("diagnostic result path");
    let raw=fs::read(&path).unwrap();
    let value:Value=serde_json::from_slice(&raw).unwrap();
    let hierarchy=&value["result"]["hierarchy"];
    let label=hierarchy["app_label"].as_str().unwrap_or("");
    let text:BTreeSet<_>=hierarchy["observations"].as_array().unwrap().iter().filter_map(|node|
        history::project(node["description"].as_str().unwrap_or(""),node["role"].as_str().unwrap_or(""),label)).collect();
    let context=history::Context{pid:hierarchy["app_pid"].as_i64().unwrap() as i32,label:label.to_owned(),text:history::bounded_text(text)};
    let mut changes=history::Changes::default();
    let mut records=Vec::new();
    for second in 0..1200 { if let Some(value)=changes.observe(context.clone(),second*3) { records.push(value); } }
    let bytes:usize=records.iter().map(|row|row.to_string().len()+1).sum();
    println!("{}",serde_json::json!({"validation":"offline replay of previously observed 32-item diagnostic; not a live hour",
        "old_diagnostic_bytes":raw.len(),"unchanged_samples":1200,"new_records":records.len(),
        "event_bytes_excluding_file_header":bytes,"records":records}));
}
