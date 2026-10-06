use std::{fs,path::PathBuf,time::{Duration,SystemTime,UNIX_EPOCH}};
use idevice::{RsdService,remote_pairing::connect_tls_psk_tunnel_native,
    tcp::adapter::Adapter,rsd::RsdHandshake,heartbeat::HeartbeatClient};
use serde_json::{json,Value};
use tokio::{net::TcpStream,time::timeout};

#[tokio::main]
async fn main() -> Result<(),Box<dyn std::error::Error>> {
    let args:Vec<String>=std::env::args().collect();
    let config:Value=serde_json::from_slice(&fs::read(&args[1])?)?;
    let host=config["hosts"].as_array().unwrap().last().unwrap().as_str().unwrap();
    let hex=config["psk_hex"].as_str().unwrap();
    let key=(0..hex.len()).step_by(2).map(|i|u8::from_str_radix(&hex[i..i+2],16)).collect::<Result<Vec<_>,_>>()?;
    let stream=timeout(Duration::from_secs(4),TcpStream::connect((host,config["port"].as_u64().unwrap() as u16))).await??;
    let tunnel=timeout(Duration::from_secs(8),connect_tls_psk_tunnel_native(stream,&key)).await??;
    let info=tunnel.info.clone();
    let mut adapter=Adapter::new(Box::new(tunnel.into_inner()),info.client_address.parse()?,info.server_address.parse()?);
    adapter.set_mss((info.mtu as usize).saturating_sub(60));
    let mut adapter=adapter.to_async_handle();
    let mut rsd=RsdHandshake::new(adapter.connect(info.server_rsd_port).await?).await?;
    let mut heartbeat=HeartbeatClient::connect_rsd(&mut adapter,&mut rsd).await?;
    let endpoint=json!({"direct_rsd":true,"hosts":[info.server_address,"::1",host],
        "port":info.server_rsd_port,"expires_at_epoch":SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs_f64()+150.0,
        "ax_queries":0,"credentials":false,"mac_service_count":rsd.services.len()});
    fs::write(&args[2],serde_json::to_vec(&endpoint)?)?;
    println!("{}",endpoint);
    let stop=PathBuf::from(&args[3]);
    let beat=tokio::spawn(async move {
        let mut interval=15;
        while let Ok(next)=heartbeat.get_marco(interval).await {
            interval=next.clamp(1,30);
            if heartbeat.send_polo().await.is_err(){break;}
        }
    });
    for _ in 0..150 {
        if stop.exists(){break;}
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    beat.abort();
    let _=adapter.close().await;
    Ok(())
}
