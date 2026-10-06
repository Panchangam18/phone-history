//! Generic semantic projection and change-only storage. AX trees stay in memory.
use std::{collections::{BTreeSet, HashMap}, fs::{self, OpenOptions}, io::Write, path::{Path, PathBuf}};
use serde_json::{json, Value};

pub const CONTEXT_BYTES: usize = 512;
pub const DAILY_BYTES: u64 = 4 * 1024 * 1024;
pub const DEFAULT_STORAGE_BYTES: u64 = 512 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Context {
    // This is the observed AX process, which can be a child process. Do not
    // label it as a host app until that relationship has been established.
    pub pid: i32,
    pub label: String,
    pub text: Vec<String>,
}

pub fn project(description: &str, role: &str, app_label: &str) -> Option<String> {
    // These are platform roles, not app names or page-specific strings.
    let ignored = ["Adjustable", "TextField", "SearchField", "SecureTextField",
        "KeyboardKey", "Switch", "Slider", "Tab"];
    if role.split(',').any(|part| ignored.contains(&part.trim())) { return None; }
    let mut text = description.trim();
    // Accessibility modifiers are metadata, not page content.
    loop {
        let before = text;
        for suffix in [", Updates Frequently",", Not Enabled",", Selected", " Updates Frequently", " Not Enabled", " Selected"] {
            text = text.strip_suffix(suffix).unwrap_or(text).trim();
        }
        if text == before { break; }
    }
    for suffix in ignored {
        if text == suffix || text.ends_with(&format!(" {suffix}")) || text.ends_with(&format!(", {suffix}")) { return None; }
    }
    loop {
        let before=text;
        for suffix in ["Static Text", "StaticText", "Static", "Header", "Text", "Heading", "Link", "Image", "Button"] {
            text = text.strip_suffix(&format!(", {suffix}")).or_else(|| text.strip_suffix(&format!(" {suffix}"))).unwrap_or(text).trim();
        }
        if before==text { break; }
    }
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if text.is_empty() || text == app_label.trim() || text == role.trim() || text.contains("PlaysSound")
        || text.chars().all(|c| c.is_ascii_digit() || ":., /-%".contains(c)) { return None; }
    if clock_only(&text) {return None;}
    let has_text_role = matches!(role.split(',').next().unwrap_or("").trim(), "Static Text"|"StaticText"|"Static"|"Text"|"Header"|"Heading"|"TextArea");
    // Unspecified role is not proof of an empty layout wrapper. Web trees
    // expose short page/container labels through these same generic nodes.
    if role.trim().is_empty() {
        if ["view","container","scroll area","scroll view","window","web area","webarea","banner","navigation","main","section","group","application"].contains(&text.to_lowercase().as_str()) { return None; }
    } else if !has_text_role && (text.len() < 24 || text.split_whitespace().count() < 4) { return None; }
    Some(truncate(&text, 240))
}

pub fn clock_only(text:&str)->bool {
    let compact=text.trim().to_ascii_lowercase().replace(' ',"").replace('.',"");
    let value=compact.strip_suffix("am").or_else(||compact.strip_suffix("pm")).unwrap_or(&compact);
    let Some((hours,minutes))=value.split_once(':') else {return false;};
    !hours.is_empty() && hours.len()<=2 && minutes.len()==2 && hours.bytes().all(|b|b.is_ascii_digit()) &&
        minutes.bytes().all(|b|b.is_ascii_digit()) && hours.parse::<u32>().is_ok_and(|n|n<=23) && minutes.parse::<u32>().is_ok_and(|n|n<60)
}

fn truncate(text: &str, limit: usize) -> String {
    if text.len() <= limit { return text.to_owned(); }
    let mut end = limit;
    while !text.is_char_boundary(end) { end -= 1; }
    text[..end].to_owned()
}

pub fn bounded_text(text: BTreeSet<String>) -> Vec<String> { bounded_priority_text(BTreeSet::new(),text) }

pub fn bounded_priority_text(headings:BTreeSet<String>, text:BTreeSet<String>) -> Vec<String> {
    bounded_semantic_text(headings,text,BTreeSet::new())
}
pub fn bounded_semantic_text(headings:BTreeSet<String>, text:BTreeSet<String>, secondary:BTreeSet<String>) -> Vec<String> {
    let mut used = 0;
    let secondary=secondary.into_iter().filter(|line|!headings.contains(line) && !text.contains(line)).collect::<Vec<_>>();
    let body=text.into_iter().filter(|line|!headings.contains(line)).collect::<Vec<_>>();
    headings.into_iter().chain(body).chain(secondary).filter_map(|line| {
        if used >= CONTEXT_BYTES || line.is_empty() { return None; }
        let line = truncate(&line, CONTEXT_BYTES - used);
        used += line.len();
        Some(line)
    }).take(12).collect()
}

#[derive(Default)]
pub struct Changes {
    previous: HashMap<i32, Context>,
    vocabulary: HashMap<i32,Vec<String>>,
    active: Option<i32>,
    candidate: Option<Context>,
}
impl Changes {
    pub fn observe(&mut self, context: Context, elapsed: u64) -> Option<Value> {
        // Missing text in a partial/loading read is not evidence that previous
        // content disappeared. Avoid clearing it or recording a loading blip.
        if context.text.is_empty() && self.active==Some(context.pid) && self.previous.contains_key(&context.pid) { return None; }
        if self.candidate.as_ref() != Some(&context) {
            self.candidate = Some(context);
            return None;
        }
        let reset = self.previous.len()>=64 && !self.previous.contains_key(&context.pid);
        if reset { self.previous.clear(); self.vocabulary.clear(); }
        let previous = self.previous.get(&context.pid);
        if previous == Some(&context) && self.active == Some(context.pid) { return None; }
        let mut event = json!({"s":elapsed,"p":context.pid});
        if reset { event["reset"]=true.into(); }
        if previous.is_none() || previous.is_some_and(|p| p.label != context.label) {
            if !context.label.is_empty() { event["a"] = context.label.clone().into(); }
        }
        let vocabulary=self.vocabulary.entry(context.pid).or_default();
        let new_count=context.text.iter().filter(|x|!vocabulary.contains(x)).count();
        if vocabulary.len()+new_count>128 { vocabulary.clear(); event["reset_p"]=true.into(); }
        let mut added=Vec::new(); let mut selection=Vec::new();
        for text in &context.text {
            let index=if let Some(index)=vocabulary.iter().position(|x|x==text) { index }
                else { let index=vocabulary.len(); vocabulary.push(text.clone()); added.push(text.clone()); index };
            selection.push(index);
        }
        if !added.is_empty() { event["n"]=json!(added); }
        if added.len()!=context.text.len() && previous!=Some(&context) { event["c"]=json!(selection); }
        self.active = Some(context.pid);
        self.previous.insert(context.pid, context);
        Some(event)
    }
    pub fn observe_once(&mut self,context:Context,elapsed:u64)->Option<Value> {
        // A frame is one observed screen, not a synthetic second observation.
        self.candidate=Some(context.clone());self.observe(context,elapsed)
    }
    pub fn invalidate(&mut self) { self.candidate = None; }
}

pub struct Store {
    folder: PathBuf,
    day: u64,
    file: fs::File,
    pub bytes: u64,
    pub events: u64,
    pub full: bool,
    committed_bytes: u64,
    policy: Option<(String,u64)>,
}
impl Store {
    pub fn open(folder: &Path, epoch: u64) -> std::io::Result<Self> {
        fs::create_dir_all(folder)?;
        let day = epoch / 86400;
        let path = folder.join(format!("history-{day}.jsonl"));
        #[cfg(unix)] use std::os::unix::fs::OpenOptionsExt;
        let mut options = OpenOptions::new(); options.create(true).append(true);
        #[cfg(unix)] options.mode(0o600);
        let mut file = options.open(path)?;
        let committed_bytes=fs::read(folder.parent().unwrap_or(folder).join("capture-usage.json")).ok()
            .and_then(|b|serde_json::from_slice::<Value>(&b).ok())
            .filter(|v|v["day"].as_u64()==Some(day)).and_then(|v|v["committed_bytes"].as_u64()).unwrap_or(0);
        let bytes = committed_bytes+file.metadata()?.len();
        let header=format!("{}\n",json!({"v":2,"t":day*86400,"reset":true,"source":"AX","partial":true}));
        if bytes + header.len() as u64 <= DAILY_BYTES {
            // A restart begins a new baseline, explicitly marked in the stream.
            file.write_all(header.as_bytes())?;
        }
        let bytes = committed_bytes+file.metadata()?.len();
        let mut store=Self { folder:folder.to_owned(),day,file,bytes,events:0,full:bytes>=DAILY_BYTES,committed_bytes,policy:None };
        store.maintain(epoch)?;
        Ok(store)
    }
    fn settings(&self) -> (String,u64) {
        let path=self.folder.parent().unwrap_or(&self.folder).join("storage-settings.json");
        if !path.exists() { return ("window".into(),DEFAULT_STORAGE_BYTES); }
        // Invalid settings fail closed: retain data instead of guessing a shorter window.
        fs::read(path).ok().and_then(|b|serde_json::from_slice::<Value>(&b).ok())
            .and_then(|v| Some((v["mode"].as_str()?.to_owned(),v.get("maxBytes").map(|x|x.as_u64()).unwrap_or(Some(DEFAULT_STORAGE_BYTES))?.clamp(64*1024,5*1024*1024))))
            .unwrap_or_else(||("none".into(),DEFAULT_STORAGE_BYTES))
    }
    pub fn maintain(&mut self, epoch:u64) -> std::io::Result<bool> {
        if epoch/86400!=self.day { *self=Self::open(&self.folder.clone(),epoch)?; return Ok(true); }
        let settings=self.settings();
        self.policy=Some(settings.clone());
        let command=self.folder.parent().unwrap_or(&self.folder).join("rotate-history.json");
        let volume_rotation=settings.0=="window" && self.file.metadata()?.len() >= (settings.1/4).min(64*1024);
        let requested=settings.0=="send" && command.exists();
        if !volume_rotation && !requested { self.prune_volume(&settings)?; return Ok(false); }
        let id=if requested {
            let value:Value=serde_json::from_slice(&fs::read(&command)?)?;
            let Some(id)=value["id"].as_str().filter(|s|s.len()==36 && s.bytes().all(|c|c.is_ascii_hexdigit() || c==b'-')) else { return Ok(false) };
            id.to_owned()
        } else {
            let n=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos();
            format!("{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",(n>>96) as u32,((n>>80)&65535),((n>>64)&65535),((n>>48)&65535),n&0xffffffffffff)
        };
        let header=format!("{}\n",json!({"v":2,"t":self.day*86400,"reset":true,"source":"AX","partial":true}));
        let can_write_header=self.bytes + header.len() as u64 <= DAILY_BYTES;
        self.file.sync_all()?;
        let archive=self.folder.join(format!("history-{}-{}-{id}.jsonl",self.day,epoch));
        let usage=self.folder.parent().unwrap_or(&self.folder).join("capture-usage.json");
        let temporary=usage.with_extension("tmp");
        fs::write(&temporary,json!({"day":self.day,"committed_bytes":self.bytes}).to_string())?;
        fs::rename(temporary,usage)?;
        fs::rename(self.folder.join(format!("history-{}.jsonl",self.day)),archive)?;
        self.committed_bytes=self.bytes;
        #[cfg(unix)] use std::os::unix::fs::OpenOptionsExt;
        let mut options=OpenOptions::new();options.create(true).append(true);
        #[cfg(unix)] options.mode(0o600);
        self.file=options.open(self.folder.join(format!("history-{}.jsonl",self.day)))?;

        if can_write_header { self.file.write_all(header.as_bytes())?;self.file.flush()?;self.bytes+=header.len() as u64; }
        if requested { fs::remove_file(command)?; }
        self.prune_volume(&settings)?;
        Ok(true)
    }
    fn prune_volume(&self, settings:&(String,u64)) -> std::io::Result<()> {
        if settings.0!="window" { return Ok(()); }
        let active=format!("history-{}.jsonl",self.day);
        let mut files=Vec::new();let mut bytes=0;
        for entry in fs::read_dir(&self.folder)? {
            let entry=entry?;let name=entry.file_name().to_string_lossy().into_owned();
            if let Some(day)=history_day(&name) {
                let metadata=entry.metadata()?;
                if !entry.file_type()?.is_file() { continue; }
                bytes+=metadata.len();
                if name!=active { files.push((day,metadata.modified()?,entry.path(),metadata.len())); }
            }
        }
        files.sort_by_key(|(day,time,_,_)|(*day,*time));
        for (_,_,path,size) in files { if bytes<=settings.1 { break; } fs::remove_file(path)?;bytes=bytes.saturating_sub(size); }
        Ok(())
    }
    pub fn retained_bytes_today(&self) -> u64 {
        fs::read_dir(&self.folder).into_iter().flatten().filter_map(Result::ok)
            .filter(|e|history_day(&e.file_name().to_string_lossy())==Some(self.day))
            .filter_map(|e|e.metadata().ok()).map(|m|m.len()).sum()
    }
    pub fn push(&mut self, event: &Value, epoch: u64) -> std::io::Result<bool> {
        if epoch / 86400 != self.day { *self = Self::open(&self.folder.clone(),epoch)?; }
        let row = format!("{event}\n");
        if self.bytes + row.len() as u64 > DAILY_BYTES { self.full = true; return Ok(false); }
        self.file.write_all(row.as_bytes())?;
        self.file.flush()?;
        self.bytes += row.len() as u64;
        self.events += 1;
        let settings=self.settings();self.prune_volume(&settings)?;
        Ok(true)
    }
}

fn history_day(name:&str) -> Option<u64> {
    name.strip_prefix("history-")?.strip_suffix(".jsonl")?.split('-').next()?.parse().ok()
}

#[cfg(test)]
mod tests {
    fn storage_fixture() -> (PathBuf,PathBuf) {
        static FIXTURE_ID:std::sync::atomic::AtomicU64=std::sync::atomic::AtomicU64::new(0);
        let root=std::env::temp_dir().join(format!("phone-retention-{}-{}-{}",std::process::id(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos(),FIXTURE_ID.fetch_add(1,std::sync::atomic::Ordering::Relaxed)));
        let records=root.join("Records");fs::create_dir_all(&records).unwrap();(root,records)
    }
    #[test] fn no_removal_and_invalid_policy_retain_old_segments() {
        let (root,records)=storage_fixture();
        fs::write(records.join("history-1.jsonl"),"old").unwrap();
        fs::write(root.join("storage-settings.json"),r#"{"mode":"none","days":7}"#).unwrap();
        let mut store=Store::open(&records,10*86400).unwrap();
        assert!(records.join("history-1.jsonl").exists());
        fs::write(root.join("storage-settings.json"),"invalid").unwrap();store.maintain(10*86400).unwrap();
        assert!(records.join("history-1.jsonl").exists());fs::remove_dir_all(root).unwrap();
    }
    #[test] fn volume_window_applies_while_running_and_only_to_owned_segments() {
        let (root,records)=storage_fixture();let mut store=Store::open(&records,10*86400).unwrap();
        fs::write(records.join("history-8-123-00000000-0000-0000-0000-000000000000.jsonl"),vec![b'x';70000]).unwrap();
        fs::write(records.join("personal.jsonl"),"keep").unwrap();
        fs::write(root.join("storage-settings.json"),r#"{"mode":"window","maxBytes":65536}"#).unwrap();store.maintain(10*86400).unwrap();
        assert!(!records.join("history-8-123-00000000-0000-0000-0000-000000000000.jsonl").exists());
        assert!(records.join("personal.jsonl").exists());assert!(records.join("history-10.jsonl").exists());fs::remove_dir_all(root).unwrap();
    }
    #[test] fn volume_rotation_bounds_total_and_keeps_daily_quota_across_restart() {
        let (root,records)=storage_fixture();
        fs::write(root.join("storage-settings.json"),r#"{"mode":"window","maxBytes":65536}"#).unwrap();
        let mut store=Store::open(&records,10*86400).unwrap();
        for n in 0..240 {
            store.maintain(10*86400+n).unwrap();
            store.push(&json!({"s":n,"p":1,"a":"Fixture","n":["x".repeat(480)]}),10*86400+n).unwrap();
            assert!(store.retained_bytes_today()<=65536);
        }
        let written=store.bytes;assert!(written>65536);assert!(store.retained_bytes_today()<written);
        assert!(fs::read_to_string(records.join("history-10.jsonl")).unwrap().starts_with("{\"partial\":true"));
        drop(store);let reopened=Store::open(&records,10*86400+241).unwrap();
        assert!(reopened.bytes>=written);assert!(reopened.retained_bytes_today()<=65536);fs::remove_dir_all(root).unwrap();
    }
    #[test] fn offload_rotation_is_standalone_and_does_not_reset_daily_quota() {
        let (root,records)=storage_fixture();
        fs::write(root.join("storage-settings.json"),r#"{"mode":"send","days":7}"#).unwrap();
        let mut store=Store::open(&records,10*86400).unwrap();store.push(&json!({"s":1,"p":1,"n":["saved"]}),10*86400+1).unwrap();let written=store.bytes;
        fs::write(root.join("rotate-history.json"),r#"{"id":"00000000-0000-0000-0000-000000000000"}"#).unwrap();
        assert!(store.maintain(10*86400+2).unwrap());
        let archive=records.join("history-10-864002-00000000-0000-0000-0000-000000000000.jsonl");
        assert!(fs::read_to_string(&archive).unwrap().contains("saved"));
        let baseline=fs::read_to_string(records.join("history-10.jsonl")).unwrap();assert!(baseline.contains("\"reset\":true"));assert!(!baseline.contains("saved"));
        fs::remove_file(&archive).unwrap();drop(store);let reopened=Store::open(&records,10*86400+3).unwrap();
        assert!(reopened.bytes>written);assert!(reopened.retained_bytes_today()<reopened.bytes);fs::remove_dir_all(root).unwrap();
    }
    #[test] fn short_unspecified_labels_and_rich_interactive_content_are_generic() {
        use super::*;
        assert_eq!(project("Example Site ","",""),Some("Example Site".into()));
        assert_eq!(project("banner ","",""),None);
        assert_eq!(project("Photo of a person walking through a forest Image","Image",""),Some("Photo of a person walking through a forest".into()));
        assert_eq!(project("Search Button","Button",""),None);
        assert_eq!(project("Private entered words in a password field SecureTextField","SecureTextField",""),None);
        let first="Primary paragraph content ".repeat(12);
        let selected=bounded_semantic_text(BTreeSet::new(),BTreeSet::from([first.clone()]),BTreeSet::from(["An incidental control with a long label".into()]));
        assert_eq!(selected[0],first);
        assert!(selected.iter().map(String::len).sum::<usize>()<=CONTEXT_BYTES);
    }
    use super::*;
    fn context(pid:i32, text:&[&str]) -> Context { Context {pid,label:"Example".into(),text:text.iter().map(|s|s.to_string()).collect()} }
    #[test] fn status_clocks_do_not_become_context_events() {
        for text in ["7:58 PM","7:58pm","19:58","9:05 A.M."] {assert!(clock_only(text));assert!(project(text,"Static Text","").is_none());}
        assert!(!clock_only("Meeting at 7:58 PM"));assert!(!clock_only("Chapter 7:58"));
    }
    #[test] fn one_visual_frame_writes_once_and_reentry_uses_references() {
        let mut changes=Changes::default();
        assert!(changes.observe_once(context(1,&["First visual page"]),0).is_some());
        for i in 1..100 {assert!(changes.observe_once(context(1,&["First visual page"]),i).is_none());}
        assert!(changes.observe_once(context(1,&["Second visual page"]),101).is_some());
        let event=changes.observe_once(context(1,&["First visual page"]),102).unwrap();
        assert_eq!(event["c"],json!([0]));assert!(event.get("n").is_none());
    }
    #[test] fn memories_share_the_evidence_write_quota() {
        let (root,folder)=storage_fixture();let mut store=Store::open(&folder,10*86400).unwrap();
        let initial=store.bytes;
        assert!(store.push(&json!({"kind":"memory","id":"m-fixture","sources":["e-fixture"],"summary":"Summary"}),10*86400+1).unwrap());
        assert!(store.bytes>initial);
        assert!(fs::read_to_string(folder.join("history-10.jsonl")).unwrap().contains("m-fixture"));
        fs::remove_dir_all(root).unwrap();
    }
    #[test] fn unchanged_hours_write_one_event() {
        let mut changes=Changes::default(); let mut events=Vec::new();
        for i in 0..1200 { if let Some(e)=changes.observe(context(1,&["A paragraph worth remembering"]),i*3) { events.push(e); } }
        assert_eq!(events.len(),1);
        assert!(events[0].to_string().len()<120);
    }
    #[test] fn updates_contain_new_content_and_references_not_asserted_removals() {
        let mut changes=Changes::default();
        for _ in 0..2 { changes.observe(context(1,&["Kept","Removed"]),0); }
        let next=context(1,&["Added","Kept"]);
        assert!(changes.observe(next.clone(),3).is_none());
        let event=changes.observe(next,6).unwrap();
        assert_eq!(event["n"],json!(["Added"])); assert_eq!(event["c"],json!([2,0]));
        assert!(event.get("r").is_none());
        assert!(event.get("a").is_none());
    }
    #[test] fn app_reentry_is_an_event_without_repeated_text() {
        let mut changes=Changes::default();
        for p in [1,2,1] { changes.observe(context(p,&["Unchanged"]),0); let event=changes.observe(context(p,&["Unchanged"]),1).unwrap();
            if p==1 && event.get("a").is_none() { assert_eq!(event,json!({"s":1,"p":1})); }
        }
    }
    #[test] fn controls_and_unicode_bounds_are_generic() {
        assert!(project("Explore Link","Link","").is_none());
        assert!(project("Story by person Button","Button","").is_none());
        assert!(project("12:23","StaticText","").is_none());
        assert_eq!(project("An interesting heading Header","Header",""),Some("An interesting heading".into()));
        assert!(project("25% Not Enabled, Updates Frequently","","").is_none());
        assert_eq!(project("A useful sentence Static","Static",""),Some("A useful sentence".into()));
        assert!(project("Header","Header","").is_none());
        let text=bounded_text(BTreeSet::from(["🧠".repeat(300)]));
        assert!(text.iter().map(String::len).sum::<usize>()<=CONTEXT_BYTES);
    }
    #[test] fn web_heading_survives_budget_and_platform_spaced_role() {
        let title="Travelling to a new country";
        assert_eq!(project(&format!("{title} Static Text, Header"),"Static Text",""),Some(title.into()));
        assert_eq!(project("Uploaded by Example. Static Text","Static Text",""),Some("Uploaded by Example.".into()));
        assert_eq!(project("Short title Header, Selected","Header, Selected",""),Some("Short title".into()));
        let body=BTreeSet::from(["A".repeat(240),"B".repeat(240),"C".repeat(240)]);
        let saved=bounded_priority_text(BTreeSet::from([title.into()]),body);
        assert_eq!(saved[0],title); assert!(saved.iter().map(String::len).sum::<usize>()<=CONTEXT_BYTES);
    }
    #[test] fn revisiting_text_uses_references_without_losing_the_visit() {
        let mut changes=Changes::default();
        for text in ["First page","Second page","First page"] {
            let c=context(1,&[text]); changes.observe(c.clone(),0);
            let event=changes.observe(c,1).unwrap();
            if text=="First page" && event.get("n").is_none() { assert_eq!(event["c"],json!([0])); }
        }
    }
    #[test] fn empty_partial_read_does_not_remove_previous_content() {
        let mut changes=Changes::default();
        for _ in 0..2 { changes.observe(context(1,&["Content"]),0); }
        for _ in 0..4 { assert!(changes.observe(context(1,&[]),1).is_none()); }
        assert!(changes.observe(context(1,&["Content"]),2).is_none());
    }
    #[test] fn daily_limit_and_retention_do_not_touch_other_files() {
        let (root,folder)=storage_fixture();
        fs::write(folder.join("history-1.jsonl"),"old").unwrap();
        fs::write(folder.join("unrelated.txt"),"keep").unwrap();
        let file=fs::File::create(folder.join("history-10.jsonl")).unwrap();
        file.set_len(DAILY_BYTES-2).unwrap(); drop(file);
        let mut store=Store::open(&folder,10*86400).unwrap();
        assert!(!store.push(&json!({"s":1,"p":1}),10*86400+1).unwrap());
        assert_eq!(store.bytes,DAILY_BYTES-2);
        assert!(store.full);
        assert!(!folder.join("history-1.jsonl").exists());
        assert!(folder.join("unrelated.txt").exists());
        fs::remove_dir_all(root).unwrap();
    }
}
