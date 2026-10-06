mod history;
mod sampling;
mod resources;
use std::{collections::{BTreeSet, HashMap, HashSet, VecDeque}, ffi::{CStr, CString, c_char},
    fs::{self, OpenOptions}, io::Write, path::Path, sync::atomic::{AtomicBool, Ordering}, time::{Duration, Instant, SystemTime, UNIX_EPOCH}};
use idevice::{Idevice, ReadWrite, RsdService,
    dvt::{message::AuxValue, remote_server::RemoteServerClient, screenshot::ScreenshotClient, device_info::DeviceInfoClient},
    heartbeat::HeartbeatClient,
    remote_pairing::{CdTunnel, RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native},
    rsd::RsdHandshake, tcp::adapter::Adapter};
use plist::{Dictionary, Value};
use serde_json::{json, Value as Json};
use base64::{Engine, engine::general_purpose::STANDARD};
use tokio::{net::{TcpSocket, TcpStream}, time::timeout};
use tokio::io::AsyncReadExt;
use std::{net::SocketAddr, os::fd::AsRawFd};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
const HOST_NAME: &str = "Phone History Probe";
const SERVICE: &str = "com.apple.accessibility.axAuditDaemon.remoteserver.shim.remote";
static STOP: AtomicBool = AtomicBool::new(false);
static STOP_NOTIFY: tokio::sync::Notify = tokio::sync::Notify::const_new();
#[derive(Clone,Copy)]
enum ManualKind { Accessibility, Screenshot }
static MANUAL: std::sync::Mutex<Option<(Instant,ManualKind,std::sync::mpsc::Sender<Json>)>> = std::sync::Mutex::new(None);
type VisionReader=unsafe extern "C" fn(*const u8,usize,f64)->*mut c_char;
static VISION_READER:std::sync::Mutex<Option<VisionReader>>=std::sync::Mutex::new(None);
static MEMORY_ROWS:std::sync::Mutex<VecDeque<(Instant,Json,std::sync::mpsc::Sender<bool>)>>=std::sync::Mutex::new(VecDeque::new());
static BACKGROUND_WORKER: std::sync::Mutex<()> = std::sync::Mutex::new(());
static CONNECTION_STAGE: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
type TunnelConnector = unsafe extern "C" fn(*const c_char, u16) -> i32;
static TUNNEL_CONNECTOR: std::sync::Mutex<Option<TunnelConnector>> = std::sync::Mutex::new(None);
const OFF: &[(&str, bool)] = &[
    ("deviceSetAppMonitoringEnabled:", false),
    ("deviceInspectorEnable:", false),
    ("deviceInspectorShowVisuals:", false),
    ("deviceEnableHighlight:", false),
];

fn now() -> f64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64() }
fn dict(items: Vec<(&str, Value)>) -> Value {
    Value::Dictionary(items.into_iter().map(|(k,v)| (k.to_owned(),v)).collect::<Dictionary>())
}
fn pass(value: Value) -> Value { dict(vec![("ObjectType", "passthrough".into()), ("Value", value)]) }
fn attribute(name: &str) -> Value {
    let mut fields = vec![("AttributeNameValue_v1", pass(name.into())),
                          ("HumanReadableNameValue_v1", pass(name.into()))];
    for key in ["DisplayAsTree_v1", "IsInternal_v1", "PerformsActionValue_v1", "SettableValue_v1", "ValueTypeValue_v1"] {
        fields.push((key, pass(0i64.into())));
    }
    dict(vec![("ObjectType", "AXAuditElementAttribute_v1".into()), ("Value", pass(dict(fields)))])
}
fn unwrap(mut value: &Value) -> &Value {
    while let Some(d) = value.as_dictionary() {
        if !d.contains_key("ObjectType") { break; }
        match d.get("Value") { Some(v) => value = v, None => break }
    }
    value
}
fn field<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    unwrap(value).as_dictionary()?.get(key).map(unwrap)
}
fn token(value: &Value) -> Result<&[u8]> {
    field(value, "PlatformElementValue_v1").and_then(Value::as_data)
        .filter(|b| b.len() == 20).ok_or_else(|| "Unexpected AX token".into())
}
fn pid(value: &Value) -> Result<i32> {
    let p = i32::from_le_bytes(token(value)?[..4].try_into()?);
    if p <= 0 { return Err("Invalid AX PID".into()); } Ok(p)
}
fn app_handle(p: i32) -> Value {
    let mut b = p.to_le_bytes().to_vec();
    b.extend(0u64.to_le_bytes()); b.extend(1u64.to_le_bytes());
    dict(vec![("ObjectType", "AXAuditElement_v1".into()),
        ("Value", pass(dict(vec![("PlatformElementValue_v1", pass(Value::Data(b)))])))])
}

struct CachedContext { signature: Vec<Value>, context: history::Context, expanded: Instant }
#[derive(Default)] struct ReadStats { hierarchy_calls:u64, cache_hits:u64, rpc_calls:u64,
    fresh_walks:u64, capped_walks:u64, last_frontier_pending:usize }
struct Audit { server: RemoteServerClient<Box<dyn ReadWrite>>, cache: Option<CachedContext>, label_cache: Option<(i32,String)>, process_label_cache:Option<(i32,String)>, stats:ReadStats }
impl Audit {
    fn new(stream: Box<dyn ReadWrite>) -> Self {
        Self { server: RemoteServerClient::with_label(stream, "phone-history-quiet-AX"), cache:None, label_cache:None, process_label_cache:None, stats:ReadStats::default() }
    }
    async fn invoke(&mut self, selector: &str, args: Vec<Value>, reply: bool) -> Result<Value> {
        if reply && STOP.load(Ordering::Relaxed) { return Err("Capture stopped".into()); }
        let allowed = match selector {
            "deviceFetchSpecialElement:" => args == vec![0i64.into()],
            "deviceElement:valueForAttribute:" => args.len() == 2 &&
                field(&args[1], "AttributeNameValue_v1").and_then(Value::as_string)
                    .is_some_and(|a| matches!(a, "Label" | "_AXHierarchyElementsAttribute")),
            "deviceInspectorSetMonitoredEventType:" => !reply && args == vec![0i64.into()],
            "devicePerformFinalCleanup" => !reply && args.is_empty(),
            s if OFF.iter().any(|(a,_)| *a == s) => !reply && args == vec![false.into()],
            _ => false,
        };
        if !allowed { return Err("Command outside quiet allowlist".into()); }
        self.stats.rpc_calls+=1;
        let args=Some(args.into_iter().map(AuxValue::archived_value).collect());
        if !reply {
            self.server.call_method(0,Some(selector),args,false).await?;
            return Ok(Value::String(String::new()));
        }
        let message=timeout(Duration::from_millis(1500),
            self.server.call_method_with_reply(0,Some(selector),args)).await??;
        if message.payload_header.serialize()[0] == 4 { return Err("AX service rejected request".into()); }
        // DTX nil/void replies are valid for absent AX attributes, notably a
        // web-content process's app label. They are not transport failures.
        Ok(message.data.unwrap_or_else(|| Value::String(String::new())))
    }

    async fn cleanup(&mut self) -> usize {
        let mut failures = 0;
        for (s,_) in OFF {
            if !matches!(timeout(Duration::from_secs(1), self.invoke(s, vec![false.into()], false)).await, Ok(Ok(_))) { failures += 1; }
        }
        if !matches!(timeout(Duration::from_secs(1), self.invoke("deviceInspectorSetMonitoredEventType:", vec![0i64.into()], false)).await, Ok(Ok(_))) { failures += 1; }
        if !matches!(timeout(Duration::from_secs(1), self.invoke("devicePerformFinalCleanup", vec![], false)).await, Ok(Ok(_))) { failures += 1; }
        failures
    }
    async fn hierarchy_probe(&mut self, read_limit: usize, expected_pid: i32) -> Result<Json> {
        // Special element 0 is an element, not a documented foreground-app API.
        // Keep its PID as diagnostic evidence; query the explicitly requested
        // application handle without treating a mismatch as an app transition.
        let special_before = self.invoke("deviceFetchSpecialElement:", vec![0i64.into()], true).await?;
        let special_pid_before = pid(&special_before).ok();
        let p = expected_pid;
        let app = app_handle(p);
        let label = self.invoke("deviceElement:valueForAttribute:", vec![app.clone(), attribute("Label")], true).await?;
        let mut queue = VecDeque::from([app]);
        let mut seen = HashSet::from([token(&queue[0])?.to_vec()]);
        let mut descriptions = HashSet::new();
        let mut observations = Vec::new();
        let mut reads = 0;
        let mut decoded_nodes = 0;
        let mut node_pids = HashSet::new();
        while let Some(element) = queue.pop_front() {
            if reads >= read_limit || seen.len() >= 500 || STOP.load(Ordering::Relaxed) {
                queue.push_front(element); break;
            }
            let reply = self.invoke("deviceElement:valueForAttribute:",
                vec![element, attribute("_AXHierarchyElementsAttribute")], true).await?;
            reads += 1;
            collect_nodes(&reply, &mut |fields| {
                let Some(child) = fields.get("AuditElementValue_v1") else { return; };
                let Ok(t) = token(child) else { return; };
                decoded_nodes += 1;
                if let Ok(child_pid) = pid(child) { node_pids.insert(child_pid); }
                let description = fields.get("HumanReadableDescriptionValue_v1").map(unwrap)
                    .and_then(Value::as_string).unwrap_or("");
                let role = fields.get("HumanReadableRoleDescriptionValue_v1").map(unwrap)
                    .and_then(Value::as_string).unwrap_or("");
                if observations.len() < 32 && !description.trim().is_empty()
                    && descriptions.insert((description.to_owned(),role.to_owned())) {
                    observations.push(json!({"description":description.chars().take(160).collect::<String>(),
                        "role":role.chars().take(80).collect::<String>()}));
                }
                if seen.len() < 500 && seen.insert(t.to_vec()) { queue.push_back(child.clone()); }
            });
        }
        let end_label = self.invoke("deviceElement:valueForAttribute:",
            vec![app_handle(p), attribute("Label")], true).await?;
        if unwrap(&label) != unwrap(&end_label) { return Err("Target application label changed; observations discarded".into()); }
        let special_after = self.invoke("deviceFetchSpecialElement:", vec![0i64.into()], true).await?;
        let mut node_pids: Vec<_> = node_pids.into_iter().collect();
        node_pids.sort();
        Ok(json!({"app_pid":p,"app_label":unwrap(&label).as_string().unwrap_or(""),
            "identity_source":"explicit_target_application_handle","target_label_unchanged":true,
            "foreground_identity_verified":false,"special_element_pid_before":special_pid_before,
            "special_element_pid_after":pid(&special_after).ok(),"observed_node_pids":node_pids,
            "hierarchy_read_calls":reads,"hierarchy_read_limit":read_limit,
            "decoded_node_occurrences":decoded_nodes,"distinct_handles":seen.len().saturating_sub(1),
            "observations":observations,"hierarchy_returned":decoded_nodes>0,
            "local_frontier_exhausted":queue.is_empty(),"complete_screen":false}))
    }
    async fn snapshot(&mut self) -> Result<Json> {
        let start = now();
        let p = pid(&self.invoke("deviceFetchSpecialElement:", vec![0i64.into()], true).await?)?;
        let app = app_handle(p);
        let label = self.invoke("deviceElement:valueForAttribute:", vec![app.clone(), attribute("Label")], true).await?;
        let label = unwrap(&label).as_string().unwrap_or("").to_owned();
        let mut queue = VecDeque::from([app]);
        let mut seen = HashSet::from([token(&queue[0])?.to_vec()]);
        let mut text = HashSet::new();
        let mut reads = 2;
        let began = Instant::now();
        while let Some(element) = queue.pop_front() {
            if reads >= 128 || seen.len() >= 500 || began.elapsed() >= Duration::from_secs(6) { return Err("AX snapshot capped".into()); }
            let value = self.invoke("deviceElement:valueForAttribute:", vec![element, attribute("_AXHierarchyElementsAttribute")], true).await?;
            reads += 1;
            collect_nodes(&value, &mut |fields| {
                enqueue_observed_node(fields, &mut seen, &mut text, &mut queue);
            });
        }
        let end_pid = pid(&self.invoke("deviceFetchSpecialElement:", vec![0i64.into()], true).await?)?;
        if end_pid != p { return Err("App changed during AX snapshot".into()); }
        let mut text: Vec<_> = text.into_iter().collect();
        text.sort();
        if text.is_empty() { return Err("No semantic text observed".into()); }
        if text.len() > 64 { return Err("Semantic text capped".into()); }
        Ok(json!({"started_at_epoch":start,"ended_at_epoch":now(),"app":{"pid":p,"label":label},
            "observed_text":text,"coverage":{"local_frontier_exhausted":true,"complete_screen":false,"atomic_snapshot":false},
            "read_calls":reads+1}))
    }
    async fn observed_app(&mut self,own_pid:Option<i32>,own_label:&str)->Result<Option<(i32,String)>> {
        let root=self.invoke("deviceFetchSpecialElement:",vec![0i64.into()],true).await?;
        let Ok(p)=pid(&root) else { return Ok(None); };
        if own_pid==Some(p) { return Ok(None); }
        let label=if let Some((cached_pid,label))=&self.label_cache {
            if *cached_pid==p { Some(label.clone()) } else { None }
        } else { None };
        let label=match label { Some(label)=>label,None=> {
            let value=self.invoke("deviceElement:valueForAttribute:",vec![app_handle(p),attribute("Label")],true).await?;
            let label=unwrap(&value).as_string().unwrap_or("").trim().chars().take(64).collect::<String>();
            self.label_cache=Some((p,label.clone()));label
        }};
        if !label.is_empty() && label==own_label { return Ok(None); }
        Ok(Some((p,label)))
    }
    async fn process_label(&mut self,adapter:&mut idevice::tcp::handle::AdapterHandle,handshake:&mut RsdHandshake,p:i32)->String {
        if let Some((cached,value))=&self.process_label_cache {if *cached==p {return value.clone();}}
        let result=timeout(Duration::from_millis(700),async {
            let mut server=RemoteServerClient::connect_rsd(adapter,handshake).await?;
            let mut client=DeviceInfoClient::new(&mut server).await?;
            let processes=client.running_processes().await?;
            Ok::<String,idevice::IdeviceError>(processes.into_iter().find(|entry|entry.pid==p as u32 && entry.is_application).map(|entry| {
                let name=if entry.real_app_name.is_empty() {entry.name} else {entry.real_app_name};
                let component=name.split('/').find(|part|part.ends_with(".app")).unwrap_or(&name);
                component.strip_suffix(".app").unwrap_or(component).chars().take(64).collect()
            }).unwrap_or_default())
        }).await;
        let label=result.ok().and_then(|r|r.ok()).unwrap_or_default();
        self.process_label_cache=Some((p,label.clone()));label
    }
    async fn compact_context(&mut self, own_pid:Option<i32>, own_label:&str) -> Result<Option<history::Context>> {
        let root = self.invoke("deviceFetchSpecialElement:",vec![0i64.into()],true).await?;
        let Ok(p) = pid(&root) else { return Ok(None); };
        if own_pid==Some(p) { return Ok(None); }
        let app=app_handle(p);
        let label=if let Some((cached_pid,label))=&self.label_cache {
            if *cached_pid==p { Some(label.clone()) } else { None }
        } else { None };
        let label=match label {
            Some(label)=>label,
            None=> {
                let value=self.invoke("deviceElement:valueForAttribute:",vec![app.clone(),attribute("Label")],true).await?;
                let label=unwrap(&value).as_string().unwrap_or("").trim().chars().take(64).collect::<String>();
                self.label_cache=Some((p,label.clone()));label
            }
        };
        if !label.is_empty() && label==own_label { return Ok(None); }
        // A special element can be a leaf (e.g. Back); an absent app Label
        // does not mean its hierarchy is empty. Seed both distinct handles.
        let mut roots=vec![root.clone()];
        let distinct_root=token(&app)?!=token(&root)?;
        if distinct_root { roots.push(app); }
        let mut seen=HashSet::new();let mut signature=Vec::new();
        let mut queue=VecDeque::new();let mut headings=BTreeSet::new();let mut text=BTreeSet::new();let mut secondary=BTreeSet::new();
        for element in &roots { seen.insert(token(element)?.to_vec()); }
        for element in roots {
            let reply=self.invoke("deviceElement:valueForAttribute:",vec![element,attribute("_AXHierarchyElementsAttribute")],true).await?;
            self.stats.hierarchy_calls+=1;
            collect_context(&reply,&label,&mut headings,&mut text,&mut secondary,&mut seen,&mut queue);
            signature.push(reply);
        }
        if let Some(cache)=&self.cache {
            // A stable parent reply says nothing about its descendants. Only
            // reuse a context when the fresh replies already exhaust the tree.
            if queue.is_empty() && cache.context.pid==p && cache.signature==signature &&
                cache.context.text==history::bounded_semantic_text(headings.clone(),text.clone(),secondary.clone()) &&
                cache.expanded.elapsed()<sampling::DEEP_REFRESH {
                self.stats.cache_hits+=1;
                return Ok(Some(cache.context.clone()));
            }
        }
        let began=Instant::now();let mut calls=signature.len();
        self.stats.fresh_walks+=1;
        while calls<sampling::MAX_HIERARCHY_READS && began.elapsed()<Duration::from_millis(sampling::MAX_DESCENT_MILLIS) {
            let Some(element)=queue.pop_front() else { break; };
            // Timeouts/transport failures are not empty subtrees. Propagate
            // them so the next request cannot hide a broken service.
            let reply=self.invoke("deviceElement:valueForAttribute:",vec![element,attribute("_AXHierarchyElementsAttribute")],true).await?;
            calls+=1;self.stats.hierarchy_calls+=1;
            collect_context(&reply,&label,&mut headings,&mut text,&mut secondary,&mut seen,&mut queue);
        }
        let end=self.invoke("deviceFetchSpecialElement:",vec![0i64.into()],true).await?;
        if pid(&end).ok()!=Some(p) { self.cache=None;return Ok(None); }
        self.stats.last_frontier_pending=queue.len();
        if !queue.is_empty() { self.stats.capped_walks+=1; }
        let context=history::Context {pid:p,label,text:history::bounded_semantic_text(headings,text,secondary)};
        self.cache=Some(CachedContext {signature,context:context.clone(),expanded:Instant::now()});
        Ok(Some(context))
    }

}

fn collect_context(reply:&Value,label:&str,headings:&mut BTreeSet<String>,text:&mut BTreeSet<String>,secondary:&mut BTreeSet<String>,seen:&mut HashSet<Vec<u8>>,queue:&mut VecDeque<Value>) {
    collect_nodes(reply,&mut |fields| {
        let description=fields.get("HumanReadableDescriptionValue_v1").map(unwrap).and_then(Value::as_string).unwrap_or("");
        let role=fields.get("HumanReadableRoleDescriptionValue_v1").map(unwrap).and_then(Value::as_string).unwrap_or("");
        if let Some(value)=history::project(description,role,label) {
            if sampling::heading(role,description) { if headings.len()<12 { headings.insert(value); } }
            else if role.split(',').any(|r|matches!(r.trim(),"Button"|"Image"|"Link")) {
                if secondary.len()<64 { secondary.insert(value); }
            } else if text.len()<64 { text.insert(value); }
        }
        if sampling::expand_role(role) {
            if let Some(child)=fields.get("AuditElementValue_v1") {
                if let Ok(t)=token(child) {
                    if seen.len()<500 && seen.insert(t.to_vec()) { queue.push_back(child.clone()); }
                }
            }
        }
    });
}

fn enqueue_observed_node(fields: &Dictionary, seen: &mut HashSet<Vec<u8>>,
    text: &mut HashSet<String>, queue: &mut VecDeque<Value>) {
    let Some(child) = fields.get("AuditElementValue_v1") else { return; };
    let Ok(t) = token(child) else { return; };
    // sim-use documents token aliases between logical elements. Preserve each
    // description, while expanding each opaque handle only once to bound reads.
    let description = fields.get("HumanReadableDescriptionValue_v1").map(unwrap)
        .and_then(Value::as_string).unwrap_or("");
    if let Some(item) = project_text(description) { text.insert(item); }
    if seen.insert(t.to_vec()) { queue.push_back(child.clone()); }
}

fn collect_nodes(value: &Value, emit: &mut impl FnMut(&Dictionary)) {
    match value {
        Value::Dictionary(d) => {
            if d.get("ObjectType").and_then(Value::as_string) == Some("AXAuditNode_v1") {
                if let Some(fields) = unwrap(value).as_dictionary() { emit(fields); }
            }
            for v in d.values() { collect_nodes(v, emit); }
        },
        Value::Array(a) => for v in a { collect_nodes(v, emit); }, _ => {}
    }
}
// Initial general projection. The desktop semantic_text_v2 remains the reference.
fn project_text(description: &str) -> Option<String> {
    let s = description.trim();
    if s.is_empty() || s.contains("PlaysSound") { return None; }
    let (body, suffix) = s.rsplit_once(", ").unwrap_or((s, ""));
    if matches!(suffix, "Button"|"Image"|"Adjustable"|"TextField"|"SearchField") { return None; }
    let body = if matches!(suffix, "StaticText"|"Header"|"Text") { body } else { s };
    if body.len() < 3 || body.chars().all(|c| c.is_ascii_digit() || ":., /".contains(c)) { return None; }
    if body.chars().count() > 1024 { return None; }
    Some(body.to_owned())
}

async fn connect_socket(ip: &str, port: u16) -> Result<Box<dyn ReadWrite>> {
    let connector = *TUNNEL_CONNECTOR.lock().map_err(|_| "Tunnel connector lock poisoned")?;
    if let Some(connect) = connector {
        use std::os::fd::FromRawFd;
        let host = CString::new(ip)?;
        let fd = unsafe { connect(host.as_ptr(),port) };
        if fd < 0 { return Err("Provider tunnel connection could not be created".into()); }
        let stream = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
        stream.set_nonblocking(true)?;
        return Ok(Box::new(tokio::net::UnixStream::from_std(stream)?));
    }
    Ok(Box::new(timeout(Duration::from_secs(5), TcpStream::connect((ip, port))).await??))
}
async fn remote_client(ip: &str, port: u16) -> Result<RemotePairingClient<RpPairingSocket<Box<dyn ReadWrite>>>> {
    let stream = connect_socket(ip,port).await?;
    Ok(RemotePairingClient::new(RpPairingSocket::new(stream), HOST_NAME))
}
async fn pair(ip: &str, port: u16, path: &Path) -> Result<Json> {
    if path.exists() { return Err("Pairing already exists; no replacement performed".into()); }
    let mut record = RpPairingFile::generate(HOST_NAME);
    let mut client = remote_client(ip, port).await?;
    timeout(Duration::from_secs(30), client.connect(&mut record, || async { "000000".to_owned() })).await??;
    private_write(path, &record.to_bytes())?;
    Ok(json!({"paired":true,"paired_at_epoch":now(),"keys_logged":false}))
}
fn private_write(path: &Path, bytes: &[u8]) -> Result<()> {
    #[cfg(unix)] use std::os::unix::fs::OpenOptionsExt;
    let mut opts = OpenOptions::new(); opts.write(true).create_new(true);
    #[cfg(unix)] opts.mode(0o600);
    let mut file = opts.open(path)?; file.write_all(bytes)?; Ok(())
}
struct HeartbeatTask { task:tokio::task::JoinHandle<()>, state:std::sync::Arc<std::sync::Mutex<Json>> }
impl HeartbeatTask {
    fn abort(&self) { self.task.abort(); }
    fn status(&self)->Json { self.state.lock().map(|s|s.clone()).unwrap_or(Json::Null) }
}
impl Drop for HeartbeatTask { fn drop(&mut self) { self.task.abort(); } }

async fn connect_audit(ip: &str, port: u16, path: &Path) -> Result<(Audit, idevice::tcp::handle::AdapterHandle, HeartbeatTask, RsdHandshake)> {
    CONNECTION_STAGE.store(1,Ordering::Relaxed);
    let mut record = RpPairingFile::read_from_file(path).await?;
    let mut client = remote_client(ip, port).await?;
    CONNECTION_STAGE.store(2,Ordering::Relaxed);
    timeout(Duration::from_secs(8), async {
        client.attempt_pair_verify().await?;
        client.validate_pairing(&mut record).await
    }).await??;
    let tunnel_port = client.create_tcp_listener().await?;
    CONNECTION_STAGE.store(3,Ordering::Relaxed);
    let stream = connect_socket(ip,tunnel_port).await?;
    let tunnel = connect_tls_psk_tunnel_native(stream, client.encryption_key()).await?;
    CONNECTION_STAGE.store(4,Ordering::Relaxed);
    let our_ip = tunnel.info.client_address.parse()?;
    let their_ip = tunnel.info.server_address.parse()?;
    let rsd_port = tunnel.info.server_rsd_port;
    let mtu = tunnel.info.mtu as usize;
    let mut adapter = Adapter::new(Box::new(tunnel.into_inner()), our_ip, their_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();
    let mut handshake = RsdHandshake::new(adapter.connect(rsd_port).await?).await?;
    let service = handshake.services.get(SERVICE).ok_or("Quiet AX service not advertised")?;
    CONNECTION_STAGE.store(5,Ordering::Relaxed);
    if service.uses_remote_xpc { return Err("Unexpected AX service transport".into()); }
    let service_port = service.port;
    let mut heartbeat = HeartbeatClient::connect_rsd(&mut adapter, &mut handshake).await?;
    let heartbeat_state=std::sync::Arc::new(std::sync::Mutex::new(json!({"messages":0})));
    let report=heartbeat_state.clone();
    let beat_task=tokio::spawn(async move {
        let mut messages=0u64;
        loop {
            // Match the developer-service protocol used by pymobiledevice3:
            // receive the daemon's message, then answer Polo. Interval is
            // optional metadata, not a required field for a valid Marco.
            let value=match heartbeat.receive_message().await {
                Ok(v)=>v,
                Err(e)=>{ if let Ok(mut state)=report.lock() { state["exit_error"]=e.to_string().chars().take(120).collect::<String>().into(); } break; }
            };
            messages+=1;
            let command=value.get("Command").and_then(Value::as_string).unwrap_or("");
            if let Ok(mut state)=report.lock() {
                *state=json!({"messages":messages,"command":command,"interval_present":value.contains_key("Interval")});
            }
            if command=="SleepyTime" {
                if let Ok(mut state)=report.lock() { state["exit_error"]="device_sleep".into(); } break;
            }
            if let Err(e)=heartbeat.send_polo().await {
                if let Ok(mut state)=report.lock() { state["exit_error"]=e.to_string().chars().take(120).collect::<String>().into(); } break;
            }
        }
    });
    let beat=HeartbeatTask {task:beat_task,state:heartbeat_state};
    let mut device = Idevice::new(Box::new(adapter.connect(service_port).await?), HOST_NAME);
    if let Err(e) = device.rsd_checkin().await { beat.abort(); return Err(e.into()); }
    let stream = device.get_socket().ok_or("AX socket unavailable")?;
    CONNECTION_STAGE.store(6,Ordering::Relaxed);
    Ok((Audit::new(stream), adapter, beat, handshake))
}
async fn take_frame(adapter:&mut idevice::tcp::handle::AdapterHandle,handshake:&mut RsdHandshake)->Result<(Vec<u8>,f64)> {
    let mut server=RemoteServerClient::connect_rsd(adapter,handshake).await?;
    let mut client=ScreenshotClient::new(&mut server).await?;
    if STOP.load(Ordering::Relaxed) { return Err("Capture stopped".into()); }
    let captured_at=now();let bytes=client.take_screenshot().await?;
    if bytes.len()>8*1024*1024 || !bytes.starts_with(b"\x89PNG\r\n\x1a\n") { return Err("Unexpected screenshot image".into()); }
    Ok((bytes,captured_at))
}
async fn visual_context(audit:&mut Audit,adapter:&mut idevice::tcp::handle::AdapterHandle,handshake:&mut RsdHandshake,
    reader:VisionReader,own_pid:Option<i32>,own_label:&str)->Result<Option<history::Context>> {
    let Some((p,label))=audit.observed_app(own_pid,own_label).await? else { return Ok(None); };
    if !resources::image_budget_available() {return Err("Image processing deferred for memory headroom".into());}
    let (bytes,captured_at)=take_frame(adapter,handshake).await?;
    let pointer=unsafe {reader(bytes.as_ptr(),bytes.len(),captured_at)};
    if pointer.is_null() { return Err("On-device OCR unavailable".into()); }
    let parsed=unsafe {CStr::from_ptr(pointer)}.to_str().ok().filter(|s|s.len()<=16384).and_then(|s|serde_json::from_str::<Json>(s).ok());
    unsafe {libc::free(pointer.cast())};drop(bytes);
    let value=parsed.ok_or("Invalid OCR observation")?;
    let mut used=0;let text=value["text"].as_array().ok_or("Missing OCR text")?.iter().filter_map(|v|v.as_str())
        .take(40).filter_map(|v| { if v.is_empty() || (!own_label.is_empty() && v.split_whitespace().collect::<String>().to_lowercase().trim_start_matches(|c:char|!c.is_alphabetic()) == own_label.split_whitespace().collect::<String>().to_lowercase()) || used+v.len()>2048 { None } else {used+=v.len();Some(v.to_owned())} }).collect::<Vec<_>>();
    let root=audit.invoke("deviceFetchSpecialElement:",vec![0i64.into()],true).await?;
    if pid(&root).ok()!=Some(p) { return Ok(None); }
    if text.is_empty() { return Err("OCR returned no visible text".into()); }
    Ok(Some(history::Context {pid:p,label,text}))
}
async fn record(audit: &mut Audit, seconds: u32, output: &Path) -> Result<Json> {
    let initial_cleanup = audit.cleanup().await;
    if initial_cleanup != 0 { return Err("Unable to disable all inspector modes".into()); }
    let deadline = Instant::now() + Duration::from_secs(seconds.clamp(5,30) as u64);
    let mut file = OpenOptions::new().append(true).open(output)?;
    let mut baselines: HashMap<i64,Json> = HashMap::new();
    let mut candidate: Option<Json> = None;
    let (mut usable, mut failed, mut emitted) = (0,0,0);
    let outcome: Result<()> = async {
        while !STOP.load(Ordering::Relaxed) && Instant::now() + Duration::from_secs(2) < deadline {
            let tick = Instant::now();
            let sample = timeout(deadline.saturating_duration_since(tick).min(Duration::from_secs(8)), audit.snapshot()).await;
            if let Ok(Ok(snapshot)) = sample {
                usable += 1;
                let p = snapshot["app"]["pid"].as_i64().ok_or("Missing PID")?;
                let state = json!({"app":snapshot["app"],"observed_text":snapshot["observed_text"]});
                let previous = baselines.get(&p);
                let should_emit = previous.is_none() || (previous != Some(&state) && candidate.as_ref() == Some(&state));
                if should_emit {
                    let evidence = json!({"schema":"iphone.phone_probe.v1","observed_at_epoch":now(),
                        "source":"on_device_application_root_AX","app":snapshot["app"],"observed_text":snapshot["observed_text"],
                        "coverage":snapshot["coverage"],"actions_inferred":false});
                    writeln!(file,"{}",evidence)?; file.flush()?;
                    baselines.insert(p,state.clone()); emitted += 1;
                }
                candidate = Some(state);
            } else { failed += 1; candidate = None; }
            tokio::time::sleep(Duration::from_secs(3).saturating_sub(tick.elapsed()).min(deadline.saturating_duration_since(Instant::now()))).await;
        }
        Ok(())
    }.await;
    let cleanup = audit.cleanup().await;
    outcome?;
    Ok(json!({"usable_reads":usable,"failed_reads":failed,"records":emitted,
        "evidence_bytes":fs::metadata(output)?.len(),"cleanup_send_failures":cleanup,
        "screenshots":0,"focus_moves":0,"input_commands":0,"inspector_enabled":false,
        "runtime":"on_device_app_with_finite_background_task","background_continuity_verified":false}))
}
async fn capture(ip: &str, port: u16, path: &Path, output: &Path, seconds: u32) -> Result<Json> {
    STOP.store(false,Ordering::Relaxed);
    private_write(output,b"")?;
    let (mut audit, mut adapter, beat, _) = timeout(Duration::from_secs(20), connect_audit(ip,port,path)).await??;
    let result = record(&mut audit,seconds,output).await;
    beat.abort(); drop(audit); let _ = adapter.close().await;
    result
}

async fn vpn_ax_probe(pairing: &Path, read_limit: u32, expected_pid: i32) -> Result<Json> {
    if expected_pid <= 0 { return Err("A verified positive target PID is required".into()); }
    STOP.store(false,Ordering::Relaxed);
    let connected = timeout(Duration::from_secs(12),connect_audit("10.7.0.1",49152,pairing)).await;
    let (mut audit, mut adapter, beat, _) = match connected {
        Ok(Ok(value)) => value,
        Ok(Err(e)) => return Err(format!("Native developer/AX service connection failed: {e}").into()),
        Err(_) => return Err("Native developer/AX service connection timed out".into()),
    };
    let initial_cleanup = audit.cleanup().await;
    let result = if initial_cleanup == 0 {
        match timeout(Duration::from_secs(12),audit.hierarchy_probe(read_limit.clamp(1,256) as usize,expected_pid)).await {
            Ok(value) => value,
            Err(_) => Err("Bounded AX hierarchy query timed out".into()),
        }
    } else { Err("Unable to disable all inspector modes".into()) };
    let final_cleanup = audit.cleanup().await;
    beat.abort(); drop(audit);
    let _ = timeout(Duration::from_secs(1),adapter.close()).await;
    let mut report = json!({"schema":"iphone.vpn_ax_probe.v1","native_developer_transport_connected":true,
        "mac_in_capture_path":false,"via_local_vpn":true,"initial_cleanup_send_failures":initial_cleanup,
        "final_cleanup_send_failures":final_cleanup,"screenshots":0,"focus_moves":0,
        "input_commands":0,"ui_testing_sessions":0,"inspector_enabled":false,
        "sustained_background_capture_proven":false});
    match result {
        Ok(hierarchy) => report["hierarchy"] = hierarchy,
        Err(e) => report["hierarchy_error"] = e.to_string().into(),
    }
    Ok(report)
}

fn replace_status(path: &Path, value: &Json) -> Result<()> {
    let temporary = path.with_extension("tmp");
    if temporary.exists() { fs::remove_file(&temporary)?; }
    private_write(&temporary,value.to_string().as_bytes())?;
    fs::rename(temporary,path)?;
    Ok(())
}

async fn sleep_until_stop(duration:Duration) {
    if STOP.load(Ordering::Relaxed) { return; }
    tokio::select! { _=tokio::time::sleep(duration)=>{}, _=STOP_NOTIFY.notified()=>{} }
}
async fn background_history(pairing: &Path, folder: &Path, status: &Path) -> Result<Json> {
    STOP.store(false,Ordering::Relaxed);
    let began=Instant::now();
    let mut resources=resources::Meter::new();
    let mut store=history::Store::open(folder,now() as u64)?;
    let mut changes=history::Changes::default();
    let (mut samples,mut failures,mut connections)=(0u64,0u64,0u64);
    let mut next_status=Instant::now();
    let mut day=now() as u64/86400;
    let mut ignored_recorder_samples=0u64;
    let mut last_context:Option<history::Context>=None;
    let mut unchanged=0u32;
    let mut ocr_reads=0u64;let mut ocr_fallbacks=0u64;
    let mut retry=sampling::Retry::default();
    let mut last_error=String::new();
    let (mut prior_rpcs,mut prior_hierarchy,mut prior_cache)=(0u64,0u64,0u64);
    while !STOP.load(Ordering::Relaxed) {
        if store.maintain(now() as u64)? { changes=history::Changes::default(); }
        let connected=timeout(Duration::from_secs(12),connect_audit("10.7.0.1",49152,pairing)).await;
        match connected {
            Ok(Ok((mut audit,mut adapter,beat,mut handshake))) => {
                connections+=1;
                let connected_at=Instant::now();let mut successful=0;
                if audit.cleanup().await==0 {
                    let mut errors=0;
                    while !STOP.load(Ordering::Relaxed) {
                        let tick=Instant::now();
                        if store.maintain(now() as u64)? { changes=history::Changes::default(); }
                        let pending=MEMORY_ROWS.lock().ok().map(|mut q|q.drain(..).collect::<Vec<_>>()).unwrap_or_default();
                        for (deadline,row,ack) in pending {
                            let saved=if !STOP.load(Ordering::Relaxed) && Instant::now()<deadline {store.push(&row,now() as u64)?} else {false};let _=ack.send(saved);
                        }
                        let config=folder.parent().and_then(|p|fs::read(p.join("capture-config.json")).ok())
                            .and_then(|bytes|serde_json::from_slice::<Json>(&bytes).ok());
                        let own_pid=config.as_ref().and_then(|c|c["pid"].as_i64()).map(|p|p as i32);
                        let own_label=config.as_ref().and_then(|c|c["label"].as_str()).unwrap_or("");
                        let manual=MANUAL.lock().ok().and_then(|mut m|m.take()).filter(|(deadline,_,_)|Instant::now()<*deadline);
                        let foreground=config.as_ref().is_some_and(|c|c["foreground"].as_bool()==Some(true));
                        // Desktop image requests are separate from ephemeral OCR sampling.
                        // Open a separate Instruments channel only for this one request.
                        if let Some((deadline,ManualKind::Screenshot,sender))=&manual {
                            let shot=timeout(deadline.saturating_duration_since(Instant::now()),async {
                                let mut server=RemoteServerClient::connect_rsd(&mut adapter,&mut handshake).await?;
                                let mut client=ScreenshotClient::new(&mut server).await?;
                                if Instant::now()>=*deadline || STOP.load(Ordering::Relaxed) { return Err("Screenshot request expired".into()); }
                                let captured_at=now();
                                let bytes=client.take_screenshot().await?;
                                if bytes.len()>8*1024*1024 || !bytes.starts_with(b"\x89PNG\r\n\x1a\n") { return Err("Unexpected screenshot image".into()); }
                                Ok::<Json,Box<dyn std::error::Error+Send+Sync>>(json!({"available":true,"timestamp":captured_at,
                                    "mime_type":"image/png","data":STANDARD.encode(bytes),"stored":false}))
                            }).await;
                            let result=match shot { Ok(Ok(v))=>v,
                                Ok(Err(e))=>json!({"available":false,"reason":e.to_string().chars().take(160).collect::<String>(),"stored":false}),
                                Err(_)=>json!({"available":false,"reason":"screenshot_timeout","stored":false}) };
                            let _=sender.send(result);
                            continue;
                        }
                        let is_manual=manual.is_some();
                        if is_manual { audit.cache=None; }
                        let before_rpc=audit.stats.rpc_calls;
                        let reader=VISION_READER.lock().ok().and_then(|r|*r);
                        let mut observation_source="AX";
                        let mut read=if foreground { Ok(Ok(None)) } else if !is_manual && reader.is_some() {
                            observation_source="OCR";ocr_reads+=1;
                            timeout(Duration::from_secs(4),visual_context(&mut audit,&mut adapter,&mut handshake,reader.unwrap(),own_pid,own_label)).await
                        } else { timeout(Duration::from_secs(3),audit.compact_context(own_pid,own_label)).await };
                        if observation_source=="OCR" && !matches!(&read,Ok(Ok(_))) {
                            ocr_fallbacks+=1;observation_source="AX";
                            read=timeout(Duration::from_secs(3),audit.compact_context(own_pid,own_label)).await;
                        }
                        if let Ok(Ok(Some(context)))=&mut read {
                            if context.label.is_empty() {context.label=audit.process_label(&mut adapter,&mut handshake,context.pid).await;}
                        }
                        if let Some((_,_,sender))=manual {
                            let result=match &read {
                                Ok(Ok(Some(c)))=>json!({"available":true,"timestamp":now(),"app_label":c.label,"text":c.text,
                                    "partial":true,"rpc_calls":audit.stats.rpc_calls-before_rpc,
                                    "frontier_pending":audit.stats.last_frontier_pending,"stored":false}),
                                _=>json!({"available":false,"reason":if foreground {"recorder_foreground"} else {"read_unavailable"},"stored":false}),
                            };
                            let _=sender.send(result);
                        }
                        match read {
                            Ok(Ok(Some(context))) => {
                                samples+=1;successful+=1;errors=0;last_error.clear();
                                retry.healthy(successful,connected_at.elapsed());
                                unchanged=if last_context.as_ref()==Some(&context) { unchanged+1 } else { 0 };
                                last_context=Some(context.clone());
                                if day!=now() as u64/86400 { day=now() as u64/86400; changes=history::Changes::default(); }
                                if !is_manual {
                                    let event=if observation_source=="OCR" {changes.observe_once(context,now() as u64%86400)} else {changes.observe(context,now() as u64%86400)};
                                    if let Some(mut event)=event {
                                        event["source"]=observation_source.into();event["partial"]=true.into();event["host_app_identity_verified"]=false.into();
                                        event["id"]=format!("e-{:x}",SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos()).into();
                                        store.push(&event,now() as u64)?;
                                    }
                                }
                            },
                            Ok(Ok(None)) => {
                                // Own UI and app transitions are not broken transports.
                                ignored_recorder_samples+=1;changes.invalidate();errors=0;
                                unchanged=unchanged.saturating_add(1);
                            },
                            Ok(Err(e)) => { failures+=1;errors+=1;changes.invalidate();last_error=e.to_string().chars().take(160).collect(); },
                            Err(_) => { failures+=1;errors=3;changes.invalidate();last_error="AX context read timed out".into(); },
                        }
                        if Instant::now()>=next_status {
                            replace_status(status,&json!({"state":"running","seconds":began.elapsed().as_secs(),
                                "samples":samples,"failed_reads":failures,"connections":connections,
                                "events_today":store.events,"bytes_today":store.retained_bytes_today(),"bytes_written_today":store.bytes,"daily_limit_reached":store.full,
                                "complete_screen":false,"host_app_identity_verified":false,
                                "ignored_recorder_samples":ignored_recorder_samples,"last_error":last_error,
                                "rpc_calls":prior_rpcs+audit.stats.rpc_calls,
                                "hierarchy_calls":prior_hierarchy+audit.stats.hierarchy_calls,
                                "cached_context_reads":prior_cache+audit.stats.cache_hits,
                                "fresh_walks_this_connection":audit.stats.fresh_walks,
                                "capped_walks_this_connection":audit.stats.capped_walks,
                                "last_frontier_pending":audit.stats.last_frontier_pending,
                                "sampling_interval_seconds":sampling::visual_cadence(unchanged).as_secs(),"ocr_reads":ocr_reads,"ocr_fallbacks":ocr_fallbacks,"capture_source":"OCR with AX fallback","recorder_foreground":foreground,
                                "resources":resources.sample(),"heartbeat":beat.status(),"runtime":"packet_tunnel_provider","updated_at":now()}))?;
                            next_status=Instant::now()+Duration::from_secs(20);
                        }
                        if errors>=3 { break; }
                        // The native heartbeat shim may close while AX reads
                        // remain healthy. Retain the live reader; its own I/O
                        // errors, not an auxiliary socket, determine reconnects.
                        // One timer replaces five wakeups per second while idle.
                        sleep_until_stop((if foreground {Duration::from_secs(3)} else if VISION_READER.lock().ok().and_then(|r|*r).is_some() {sampling::visual_cadence(unchanged)} else {sampling::cadence(unchanged)}).saturating_sub(tick.elapsed())).await;
                    }
                } else { failures+=1;last_error="Unable to disable inspector modes".into(); }
                let _=audit.cleanup().await;
                prior_rpcs+=audit.stats.rpc_calls;prior_hierarchy+=audit.stats.hierarchy_calls;prior_cache+=audit.stats.cache_hits;
                beat.abort(); drop(audit);
                let _=timeout(Duration::from_secs(1),adapter.close()).await;
            },
            Ok(Err(e)) => { failures+=1;changes.invalidate();last_error=e.to_string().chars().take(160).collect(); },
            Err(_) => { failures+=1;changes.invalidate();last_error="Developer connection timed out".into(); },
        }
        if STOP.load(Ordering::Relaxed) { break; }
        let delay=retry.delay();
        replace_status(status,&json!({"state":"reconnecting","seconds":began.elapsed().as_secs(),
            "samples":samples,"failed_reads":failures,"connections":connections,"events_today":store.events,
            "bytes_today":store.retained_bytes_today(),"bytes_written_today":store.bytes,"connection_stage":CONNECTION_STAGE.load(Ordering::Relaxed),
            "retry_seconds":delay.as_secs(),"last_error":last_error,"rpc_calls":prior_rpcs,
            "hierarchy_calls":prior_hierarchy,"cached_context_reads":prior_cache,"resources":resources.sample(),"updated_at":now()}))?;
        sleep_until_stop(delay).await;
    }
    let value=json!({"state":"stopped","seconds":began.elapsed().as_secs(),"samples":samples,
        "failed_reads":failures,"connections":connections,"events_today":store.events,"bytes_today":store.retained_bytes_today(),"bytes_written_today":store.bytes,
        "resources":resources.sample(),"updated_at":now(),"complete_screen":false});
    replace_status(status,&value)?;
    Ok(value)
}

// Executes on the existing worker; no second AX connection or focus changes.
#[unsafe(no_mangle)]
pub extern "C" fn phone_history_check_now() -> *mut c_char { manual_request(ManualKind::Accessibility) }

#[unsafe(no_mangle)]
pub extern "C" fn phone_history_screenshot_now() -> *mut c_char { manual_request(ManualKind::Screenshot) }

fn manual_request(kind:ManualKind) -> *mut c_char {
    let result=(|| -> Result<Json> {
        if STOP.load(Ordering::Relaxed) || BACKGROUND_WORKER.try_lock().is_ok() { return Err("Capture is not running".into()); }
        let (sender,receiver)=std::sync::mpsc::channel();
        let deadline=Instant::now()+Duration::from_millis(3000);
        { let mut pending=MANUAL.lock().map_err(|_|"Read request unavailable")?;
          if pending.as_ref().is_some_and(|(d,_,_)|*d>Instant::now()) { return Err("A read is already pending".into()); }
          *pending=Some((deadline,kind,sender)); }
        STOP_NOTIFY.notify_one();
        receiver.recv_timeout(Duration::from_millis(3300)).map_err(|_|"Read timed out; no additional worker started".into())
    })();
    report(result)
}

#[unsafe(no_mangle)]
pub extern "C" fn phone_history_set_vision_reader(reader:Option<VisionReader>) { if let Ok(mut current)=VISION_READER.lock() { *current=reader; } }

#[unsafe(no_mangle)]
pub unsafe extern "C" fn phone_history_submit_memory(pointer:*const c_char)->u32 {
    let result=(||->Result<bool>{
        if STOP.load(Ordering::Relaxed) || BACKGROUND_WORKER.try_lock().is_ok() { return Ok(false); }
        let text=unsafe {string(pointer)}?;if text.len()>16384 {return Ok(false);}
        let row:Json=serde_json::from_str(text)?;
        if row["kind"]!="memory" || !row["id"].as_str().is_some_and(|s|s.starts_with("m-")) ||
            !row["sources"].as_array().is_some_and(|a|!a.is_empty() && a.len()<=40) {return Ok(false);}
        let (sender,receiver)=std::sync::mpsc::channel();
        {let mut q=MEMORY_ROWS.lock().map_err(|_|"Memory queue unavailable")?;if q.len()>=4 {return Ok(false);}if STOP.load(Ordering::Relaxed) {return Ok(false);}q.push_back((Instant::now()+Duration::from_secs(7),row,sender));}
        STOP_NOTIFY.notify_one();Ok(receiver.recv_timeout(Duration::from_secs(8)).unwrap_or(false))
    })();u32::from(result.unwrap_or(false))
}

#[unsafe(no_mangle)]
pub extern "C" fn phone_history_set_tunnel_connector(connector: Option<TunnelConnector>) {
    if let Ok(mut current)=TUNNEL_CONNECTOR.lock() { *current=connector; }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn phone_history_run_background(pairing_path:*const c_char, folder_path:*const c_char, status_path:*const c_char) -> *mut c_char {
    report((|| {
        let _worker=BACKGROUND_WORKER.try_lock().map_err(|_|"A capture worker is already running")?;
        let pairing=Path::new(unsafe { string(pairing_path) }?);
        let folder=Path::new(unsafe { string(folder_path) }?);
        let status=Path::new(unsafe { string(status_path) }?);
        tokio::runtime::Builder::new_current_thread().enable_all().build()?.block_on(background_history(pairing,folder,status))
    })())
}

fn report(result: Result<Json>) -> *mut c_char {
    let value = match result { Ok(v) => json!({"ok":true,"result":v}), Err(e) => json!({"ok":false,"error":e.to_string()}) };
    CString::new(value.to_string()).unwrap().into_raw()
}
unsafe fn string<'a>(pointer: *const c_char) -> Result<&'a str> {
    if pointer.is_null() { return Err("Missing argument".into()); }
    Ok(unsafe { CStr::from_ptr(pointer) }.to_str()?)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn phone_history_vpn_ax_probe(pairing_path: *const c_char, read_limit: u32, expected_pid: i32) -> *mut c_char {
    report((|| {
        let path = Path::new(unsafe { string(pairing_path) }?);
        tokio::runtime::Runtime::new()?.block_on(async {
            timeout(Duration::from_secs(23),vpn_ax_probe(path,read_limit,expected_pid)).await?
        })
    })())
}
// All pointers come from Swift withCString and stay valid for this synchronous call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn phone_history_pair(ip: *const c_char, port: u16, pairing_path: *const c_char) -> *mut c_char {
    report((|| { let ip = unsafe { string(ip) }?; let path = unsafe { string(pairing_path) }?;
        tokio::runtime::Runtime::new()?.block_on(pair(ip,port,Path::new(path))) })())
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn phone_history_capture(ip: *const c_char, port: u16, pairing_path: *const c_char, output_path: *const c_char, seconds: u32) -> *mut c_char {
    report((|| { let ip = unsafe { string(ip) }?; let path = unsafe { string(pairing_path) }?; let out = unsafe { string(output_path) }?;
        tokio::runtime::Runtime::new()?.block_on(capture(ip,port,Path::new(path),Path::new(out),seconds)) })())
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn phone_history_free(pointer: *mut c_char) {
    if !pointer.is_null() { drop(unsafe { CString::from_raw(pointer) }); }
}
#[unsafe(no_mangle)]
pub extern "C" fn phone_history_stop() {
    STOP.store(true,Ordering::Relaxed);STOP_NOTIFY.notify_one();
    if let Ok(mut queue)=MEMORY_ROWS.lock() {for (_,_,ack) in queue.drain(..) {let _=ack.send(false);}}
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn phone_history_transport_probe(ip: *const c_char, port: u16) -> *mut c_char {
    report((|| { let ip = unsafe { string(ip) }?;
        tokio::runtime::Runtime::new()?.block_on(async {
            let stream = match timeout(Duration::from_secs(3), TcpStream::connect((ip,port))).await {
                Ok(Ok(s)) => s,
                Ok(Err(e)) => return Ok(json!({"tcp_connected":false,"stage":"tcp_connect","os_error":e.raw_os_error(),"error":e.to_string()})),
                Err(_) => return Ok(json!({"tcp_connected":false,"stage":"tcp_connect","error":"Timeout"})),
            };
            if port == 62078 {
                let mut device = Idevice::new(Box::new(stream),HOST_NAME);
                return match timeout(Duration::from_secs(3), device.get_type()).await {
                    Ok(Ok(t)) => Ok(json!({"tcp_connected":true,"lockdown_query_reached":true,"daemon_type":t})),
                    Ok(Err(e)) => Ok(json!({"tcp_connected":true,"lockdown_query_reached":false,"stage":"lockdown_query_type","error":format!("{e:?}")})),
                    Err(_) => Ok(json!({"tcp_connected":true,"lockdown_query_reached":false,"stage":"lockdown_query_type","error":"Timeout"})),
                };
            }
            let mut client = RemotePairingClient::new(RpPairingSocket::new(stream),HOST_NAME);
            let handshake = match timeout(Duration::from_secs(3), client.attempt_pair_verify()).await {
                Ok(Ok(_)) => json!({"remote_pairing_handshake_reached":true,"tcp_connected":true}),
                Ok(Err(e)) => json!({"remote_pairing_handshake_reached":false,"tcp_connected":true,"stage":"developer_handshake","error":format!("{e:?}")}),
                Err(_) => json!({"remote_pairing_handshake_reached":false,"tcp_connected":true,"stage":"developer_handshake","error":"Timeout"}),
            };
            Ok(handshake)
        }) })())
}

// An authenticated Mac creates a temporary listener and passes only its session
// PSK/port to this transport-only probe. No pairing records or AX calls are used.
#[derive(Clone, Copy, Debug, PartialEq)]
enum SocketRoute { System, WifiBound, WifiBoundDirect, WifiSource }
impl SocketRoute {
    fn parse(value: &str) -> Result<Self> {
        match value {
            "system" => Ok(Self::System),
            "wifi_bound" => Ok(Self::WifiBound),
            "wifi_bound_dontroute" => Ok(Self::WifiBoundDirect),
            "wifi_source" => Ok(Self::WifiSource),
            _ => Err("Unknown socket route; no connection attempted".into()),
        }
    }
}

async fn connect_probe(ip: &str, port: u16, route: SocketRoute) -> std::io::Result<TcpStream> {
    let address = SocketAddr::new(ip.parse().map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidInput,"Numeric endpoint required"))?,port);
    if route == SocketRoute::System { return TcpStream::connect(address).await; }
    if !address.is_ipv4() { return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput,"Wi-Fi route trial requires IPv4")); }
    let socket = TcpSocket::new_v4()?;
    if matches!(route,SocketRoute::WifiBound | SocketRoute::WifiBoundDirect) {
        #[cfg(any(target_os="ios",target_os="macos"))]
        {
            let index = unsafe { libc::if_nametoindex(c"en0".as_ptr()) };
            if index == 0 { return Err(std::io::Error::new(std::io::ErrorKind::NotFound,"Wi-Fi interface en0 unavailable")); }
            let status = unsafe { libc::setsockopt(socket.as_raw_fd(),libc::IPPROTO_IP,libc::IP_BOUND_IF,
                (&index as *const u32).cast(),std::mem::size_of_val(&index) as libc::socklen_t) };
            if status != 0 { return Err(std::io::Error::last_os_error()); }
        }
        #[cfg(not(any(target_os="ios",target_os="macos")))]
        return Err(std::io::Error::new(std::io::ErrorKind::Unsupported,"Darwin interface binding required"));
    }
    if route == SocketRoute::WifiBoundDirect {
        let enabled: libc::c_int = 1;
        let status = unsafe { libc::setsockopt(socket.as_raw_fd(),libc::SOL_SOCKET,libc::SO_DONTROUTE,
            (&enabled as *const libc::c_int).cast(),std::mem::size_of_val(&enabled) as libc::socklen_t) };
        if status != 0 { return Err(std::io::Error::last_os_error()); }
    }
    if route == SocketRoute::WifiSource { socket.bind(SocketAddr::new(address.ip(),0))?; }
    socket.connect(address).await
}

fn peek_tls_header(fd: libc::c_int) -> Json {
    let mut header = [0u8;5];
    // Observe record type only; never consume/decrypt/log application payload.
    let count = unsafe { libc::recv(fd,header.as_mut_ptr().cast(),header.len(),libc::MSG_PEEK|libc::MSG_DONTWAIT) };
    if count == 0 { return json!({"state":"eof","cdtunnel_request_sent":false}); }
    if count < 0 {
        let error = std::io::Error::last_os_error();
        return json!({"state":if error.kind()==std::io::ErrorKind::WouldBlock {"no_pending_record"} else {"socket_error"},
            "os_error":error.raw_os_error(),"cdtunnel_request_sent":false});
    }
    json!({"state":"record_pending","tls_record_type":header[0],"header_bytes_available":count,
        "cdtunnel_request_sent":false,"payload_bytes_logged":0})
}

async fn probe_listener(config_path: &Path) -> Result<Json> {
    let config: Json = serde_json::from_slice(&fs::read(config_path)?)?;
    let expires = config["expires_at_epoch"].as_f64().ok_or("Missing expiration")?;
    if now() >= expires { return Err("Temporary listener configuration expired".into()); }
    let port = config["port"].as_u64().filter(|p| *p > 0 && *p <= 65535).ok_or("Invalid port")? as u16;
    if config["direct_rsd"] == true { return probe_direct_rsd(&config,port,expires).await; }
    let hex = config["psk_hex"].as_str().ok_or("Missing session key")?;
    if hex.len() != 64 || !hex.is_ascii() { return Err("Invalid session key".into()); }
    let key = (0..hex.len()).step_by(2).map(|i| u8::from_str_radix(&hex[i..i+2],16))
        .collect::<std::result::Result<Vec<_>,_>>()?;
    let hosts = config["hosts"].as_array().ok_or("Missing hosts")?;
    let route_name = config["socket_route"].as_str().unwrap_or("system");
    let socket_route = SocketRoute::parse(route_name)?;
    let mut rows = Vec::new();
    for host in hosts.iter().take(3) {
        if now() >= expires { break; }
        let ip = host.as_str().ok_or("Invalid host")?;
        let mut row = json!({"address":ip,"port":port,"tcp_connected":false,"tls_psk_reached":false,
            "tunnel_handshake_reached":false,"rsd_reached":false,"ax_queries":0,"socket_route":route_name});
        let stream = match timeout(Duration::from_secs(3),connect_probe(ip,port,socket_route)).await {
            Ok(Ok(s)) => s,
            Ok(Err(e)) => {
                row["stage"] = "tcp_connect".into();
                row["os_error"] = json!(e.raw_os_error()); row["error"] = e.to_string().into();
                rows.push(row); continue;
            },
            Err(_) => { row["stage"] = "tcp_timeout".into(); rows.push(row); continue; }
        };
        row["tcp_connected"] = true.into();
        row["socket_local_address"] = stream.local_addr()?.ip().to_string().into();
        let socket_fd = stream.as_raw_fd();
        let mut tls = match timeout(Duration::from_secs(6),idevice::remote_pairing::tls_psk::tls_psk_handshake(stream,&key)).await {
            Ok(Ok(t)) => t,
            Ok(Err(e)) => {
                row["stage"] = "tls_psk_handshake".into();
                match e {
                    idevice::IdeviceError::Socket(e) => {
                        row["os_error"] = json!(e.raw_os_error()); row["error"] = e.to_string().into();
                    },
                    idevice::IdeviceError::InternalError(message) if message.starts_with("TLS Alert") => {
                        row["error"] = message.into();
                    },
                    _ => { row["error"] = "TLS protocol rejected or invalid response".into(); }
                }
                rows.push(row); continue;
            },
            Err(_) => { row["stage"] = "tls_timeout".into(); rows.push(row); continue; }
        };
        row["tls_psk_reached"] = true.into();
        row["tls_finished_verified"] = tls.server_finished_verified().into();
        if !tls.server_finished_verified() {
            row["stage"] = "tls_finished_mismatch".into();
            rows.push(row); continue;
        }
        if config["post_tls_peek"] == true {
            tokio::time::sleep(Duration::from_millis(250)).await;
            let mut notice = peek_tls_header(socket_fd);
            let peer_closed = notice["state"]=="eof" || notice["state"]=="socket_error" || notice["tls_record_type"]==21;
            if notice["tls_record_type"]==21 {
                let mut alert = [0u8;2];
                if matches!(timeout(Duration::from_secs(2),tls.read_exact(&mut alert)).await,Ok(Ok(_))) {
                    notice["tls_alert_level"]=alert[0].into();
                    notice["tls_alert_description"]=alert[1].into();
                    notice["tls_alert_authenticated"]=true.into();
                    notice["tls_alert_name"]=match alert[1] { 0=>"close_notify",40=>"handshake_failure",_=>"other_alert" }.into();
                }
            }
            row["post_tls_observation"] = notice;
            if peer_closed {
                row["stage"]="peer_closed_before_cdtunnel_request".into();
                rows.push(row); continue;
            }
        }
        // Restore the stream framing that reached RSD in the Mac control.
        // Keeping BufWriter around the packet adapter can leave packet writes
        // unflushed, so the build-15 experiment is not the control baseline.
        row["handshake_framing"] = "split_tls_records".into();
        let tunnel = match timeout(Duration::from_secs(6),CdTunnel::handshake(tls)).await {
            Ok(Ok(t)) => t,
            Ok(Err(e)) => {
                row["stage"] = "cdtunnel_handshake".into();
                if let idevice::IdeviceError::Socket(e) = e {
                    row["os_error"] = json!(e.raw_os_error()); row["error"] = e.to_string().into();
                } else { row["error"] = "CDTunnel protocol rejected or invalid response".into(); }
                rows.push(row); continue;
            },
            Err(_) => { row["stage"] = "cdtunnel_timeout".into(); rows.push(row); continue; }
        };
        row["tunnel_handshake_reached"] = true.into();
        let our_ip = tunnel.info.client_address.parse()?;
        let their_ip = tunnel.info.server_address.parse()?;
        let rsd_port = tunnel.info.server_rsd_port;
        let mtu = tunnel.info.mtu as usize;
        let mut adapter = Adapter::new(Box::new(tunnel.into_inner()),our_ip,their_ip);
        adapter.set_mss(mtu.saturating_sub(60));
        let mut adapter = adapter.to_async_handle();
        match timeout(Duration::from_secs(6),async {
            RsdHandshake::new(adapter.connect(rsd_port).await?).await
        }).await {
            Ok(Ok(rsd)) => {
                row["rsd_reached"] = true.into();
                row["advertised_service_count"] = json!(rsd.services.len());
                row["quiet_ax_service_advertised"] = rsd.services.contains_key(SERVICE).into();
                row["stage"] = "rsd_only_complete".into();
            },
            Ok(Err(_)) => { row["stage"] = "rsd_handshake_failed".into(); },
            Err(_) => { row["stage"] = "rsd_timeout".into(); },
        }
        let _ = adapter.close().await;
        let success = row["rsd_reached"] == true;
        rows.push(row);
        if success { break; }
    }
    Ok(json!({"schema":"iphone.listener_transport_probe.v1","checked_at_epoch":now(),
        "routes":rows,"vpn":false,"ax_queries":0,"credentials_logged":false,"capture":false}))
}

async fn probe_direct_rsd(config:&Json,port:u16,expires:f64)->Result<Json> {
    let hosts=config["hosts"].as_array().ok_or("Missing endpoint hosts")?;
    let mut rows=Vec::new();
    for host in hosts.iter().take(3) {
        if now()>=expires { break; }
        let ip=host.as_str().ok_or("Invalid host")?;
        let mut row=json!({"address":ip,"port":port,"tcp_connected":false,"rsd_reached":false,"ax_queries":0});
        match timeout(Duration::from_secs(6),async {
            let stream=TcpStream::connect((ip,port)).await?;
            row["tcp_connected"]=true.into();
            RsdHandshake::new(stream).await
        }).await {
            Ok(Ok(rsd))=>{
                row["rsd_reached"]=true.into();row["stage"]="rsd_only_complete".into();
                row["advertised_service_count"]=json!(rsd.services.len());
                row["quiet_ax_service_advertised"]=rsd.services.contains_key(SERVICE).into();
            },
            Ok(Err(idevice::IdeviceError::Socket(e)))=>{
                row["stage"]="direct_rsd_connection".into();row["error"]=e.to_string().into();row["os_error"]=json!(e.raw_os_error());
            },
            Ok(Err(_))=>{row["stage"]="direct_rsd_protocol_failed".into();},
            Err(_)=>{row["stage"]="direct_rsd_timeout".into();},
        }
        let success=row["rsd_reached"]==true;rows.push(row);if success {break;}
    }
    Ok(json!({"schema":"iphone.direct_rsd_probe.v1","checked_at_epoch":now(),"routes":rows,"ax_queries":0,"capture":false,"vpn":false}))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn phone_history_listener_probe(config_path: *const c_char) -> *mut c_char {
    report((|| {
        let path = Path::new(unsafe { string(config_path) }?);
        tokio::runtime::Runtime::new()?.block_on(async {
            timeout(Duration::from_secs(32),probe_listener(path)).await?
        })
    })())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fake_audit(replies:Vec<Option<Value>>) -> (Audit,tokio::task::JoinHandle<Vec<String>>) {
        let (client,mut peer)=tokio::io::duplex(65536);
        let server=tokio::spawn(async move {
            use idevice::dvt::message::{Message,MessageHeader,PayloadHeader};
            use tokio::io::AsyncWriteExt;
            let mut calls=Vec::new();
            for reply in replies {
                let request=Message::from_reader(&mut peer).await.unwrap();
                calls.push(request.data.as_ref().and_then(Value::as_string).unwrap().to_owned());
                let header=MessageHeader::new(0,1,u32::from_le_bytes(request.message_header.serialize()[16..20].try_into().unwrap()),1,0,false);
                let response=Message::new(header,PayloadHeader::new(),None,reply);
                peer.write_all(&response.serialize()).await.unwrap();
            }
            calls
        });
        (Audit::new(Box::new(client)),server)
    }
    #[tokio::test] async fn aliased_child_heading_is_kept_and_complete_context_can_be_reused() {
        let root=app_handle(52);
        let node=dict(vec![("ObjectType","AXAuditNode_v1".into()),("Value",pass(dict(vec![
            ("AuditElementValue_v1",root.clone()),
            ("HumanReadableDescriptionValue_v1",pass("Current video title Static Text, Header".into())),
            ("HumanReadableRoleDescriptionValue_v1",pass("Static Text".into()))]))) ]);
        let (mut audit,peer)=fake_audit(vec![Some(root.clone()),None,Some(node.clone()),Some(root.clone()),Some(root.clone()),Some(node)]);
        let first=audit.compact_context(None,"").await.unwrap().unwrap();
        assert_eq!(first.text,vec!["Current video title"]);
        let second=audit.compact_context(None,"").await.unwrap().unwrap();
        assert_eq!(first,second);
        assert_eq!(audit.stats.hierarchy_calls,2);
        assert_eq!(audit.stats.cache_hits,1);
        assert_eq!(peer.await.unwrap().len(),6);
    }
    #[tokio::test] async fn own_app_skips_label_and_hierarchy_work() {
        let (mut audit,peer)=fake_audit(vec![Some(app_handle(52))]);
        assert!(audit.compact_context(Some(52),"Recorder").await.unwrap().is_none());
        assert_eq!(peer.await.unwrap(),vec!["deviceFetchSpecialElement:"]);
        assert_eq!(audit.stats.hierarchy_calls,0);
    }
    fn test_element(p:i32, id:u8)->Value {
        let mut bytes=token(&app_handle(p)).unwrap().to_vec();bytes[4]=id;
        dict(vec![("ObjectType","AXAuditElement_v1".into()),("Value",pass(dict(vec![("PlatformElementValue_v1",pass(Value::Data(bytes)))])))])
    }
    fn test_node(element:Value, description:&str, role:&str)->Value {
        dict(vec![("ObjectType","AXAuditNode_v1".into()),("Value",pass(dict(vec![
            ("AuditElementValue_v1",element),("HumanReadableDescriptionValue_v1",pass(description.into())),
            ("HumanReadableRoleDescriptionValue_v1",pass(role.into()))])))])
    }
    #[tokio::test] async fn unchanged_parent_cannot_hide_changed_descendant() {
        let root=app_handle(52);let child=test_element(52,1);
        let parent=test_node(child.clone(),"Navigation Button","Button");
        let before=test_node(test_element(52,2),"First article heading Header","Header");
        let after=test_node(test_element(52,2),"Second article heading Header","Header");
        let (mut audit,peer)=fake_audit(vec![Some(root.clone()),None,Some(parent.clone()),Some(before),None,Some(root.clone()),
            Some(root.clone()),Some(parent),Some(after),None,Some(root)]);
        assert_eq!(audit.compact_context(None,"").await.unwrap().unwrap().text,vec!["First article heading"]);
        assert_eq!(audit.compact_context(None,"").await.unwrap().unwrap().text,vec!["Second article heading"]);
        assert_eq!(audit.stats.cache_hits,0);assert_eq!(audit.stats.hierarchy_calls,6);
        assert_eq!(peer.await.unwrap().len(),11);
    }
    #[tokio::test] async fn short_untyped_page_labels_are_preserved_without_title_inference() {
        let root=app_handle(52);
        let before=test_node(test_element(52,1),"Catalog ","");
        let after=test_node(test_element(52,1),"Collection ","");
        let (mut audit,peer)=fake_audit(vec![Some(root.clone()),None,Some(before),None,Some(root.clone()),
            Some(root.clone()),Some(after),None,Some(root)]);
        assert_eq!(audit.compact_context(None,"").await.unwrap().unwrap().text,vec!["Catalog"]);
        assert_eq!(audit.compact_context(None,"").await.unwrap().unwrap().text,vec!["Collection"]);
        assert_eq!(peer.await.unwrap().len(),9);
    }
    #[tokio::test] async fn nil_app_label_does_not_hide_application_tree_behind_special_leaf() {
        let root=test_element(52,1);
        let back=test_node(root.clone(),"Back Button","Button");
        let wrapper=test_node(test_element(52,2),"","");
        let page=test_node(test_element(52,3),"Example Site ","");
        let heading=test_node(test_element(52,3),"Current content heading Header","Header");
        let (mut audit,peer)=fake_audit(vec![Some(root.clone()),None,Some(back),Some(wrapper),Some(page),Some(heading),Some(root)]);
        let context=audit.compact_context(None,"").await.unwrap().unwrap();
        assert_eq!(context.text,vec!["Current content heading","Example Site"]);
        assert_eq!(audit.stats.hierarchy_calls,4);
        assert_eq!(peer.await.unwrap().len(),7);
    }
    #[test] fn root_handle_matches_verified_token() {
        assert_eq!(token(&app_handle(8492)).unwrap(), [8492i32.to_le_bytes().to_vec(),0u64.to_le_bytes().to_vec(),1u64.to_le_bytes().to_vec()].concat());
        assert_eq!(pid(&app_handle(8492)).unwrap(),8492);
    }
    #[test] fn route_configuration_rejects_unknown_interface_controls() {
        assert!(SocketRoute::parse("vpn").is_err());
        assert!(SocketRoute::parse("arbitrary-interface").is_err());
        assert_eq!(SocketRoute::parse("wifi_bound").unwrap(),SocketRoute::WifiBound);
        assert_eq!(SocketRoute::parse("system").unwrap(),SocketRoute::System);
    }
    #[test] fn initial_projection_discards_clock_and_keyboard_noise() {
        assert_eq!(project_text("10:42, StaticText"),None);
        assert_eq!(project_text("A, KeyboardKey, PlaysSound"),None);
        assert_eq!(project_text("Search, Button"),None);
        assert_eq!(project_text("Meeting notes, Header"),Some("Meeting notes".into()));
    }
    #[test] fn aliased_handle_retains_both_descriptions_without_extra_reads() {
        let child = app_handle(1234);
        let mut seen = HashSet::new();
        let mut text = HashSet::new();
        let mut queue = VecDeque::new();
        for description in ["Project alpha, StaticText", "Project beta, StaticText", "Project alpha, StaticText"] {
            let fields = dict(vec![("AuditElementValue_v1", child.clone()),
                ("HumanReadableDescriptionValue_v1", pass(description.into()))]);
            enqueue_observed_node(fields.as_dictionary().unwrap(), &mut seen, &mut text, &mut queue);
        }
        assert_eq!(text, HashSet::from(["Project alpha".into(), "Project beta".into()]));
        assert_eq!(queue.len(), 1);
        assert_eq!(seen.len(), 1);
    }
    #[test] fn root_alias_preserves_text_without_reenqueuing_root() {
        let child = app_handle(1234);
        let mut seen = HashSet::from([token(&child).unwrap().to_vec()]);
        let mut text = HashSet::new();
        let mut queue = VecDeque::new();
        let fields = dict(vec![("AuditElementValue_v1", child),
            ("HumanReadableDescriptionValue_v1", pass("Meeting notes, Header".into()))]);
        enqueue_observed_node(fields.as_dictionary().unwrap(), &mut seen, &mut text, &mut queue);
        assert_eq!(text, HashSet::from(["Meeting notes".into()]));
        assert!(queue.is_empty());
    }
}
