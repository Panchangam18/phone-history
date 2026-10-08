import Foundation
import ImageIO
import UniformTypeIdentifiers
import NetworkExtension
import Darwin

@objc(PacketTunnelProvider)
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let lock = NSLock()
    private var connections: [UUID:TunnelConnection] = [:]
    private var worker: Thread?
    private var stopped = false
    private var starting = false
    private var memoryEngine:MemoryEngine?
    private var desktopServer: DesktopExportServer?

    override func startTunnel(options: [String:NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        lock.lock()
        if starting || (worker != nil && worker?.isFinished == false) {
            lock.unlock()
            completionHandler(NSError(domain:"PhoneHistory",code:8,userInfo:[NSLocalizedDescriptionKey:"Capture is already starting or running."]))
            return
        }
        starting = true; stopped = false; lock.unlock()
        do {
            let folder = try HistoryPaths.folder()
            let pairing = folder.appendingPathComponent("remote-pairing.plist")
            guard FileManager.default.fileExists(atPath: pairing.path) else {
                throw NSError(domain: "PhoneHistory", code: 2, userInfo: [NSLocalizedDescriptionKey: "Developer trust has not been imported."])
            }
            // Narrow local route, following LocalDevVPN's address-swapping
            // transport. Ordinary internet traffic is excluded from the tunnel.
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
            let ipv4 = NEIPv4Settings(addresses: ["10.7.1.1"], subnetMasks: ["255.255.255.255"])
            ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")]
            ipv4.excludedRoutes = [.default()]
            settings.ipv4Settings = ipv4
            settings.mtu = 1500
            setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self else { completionHandler(error); return }
                self.lock.lock()
                let cancelled = self.stopped || !self.starting
                self.starting = false
                self.lock.unlock()
                guard error == nil else { completionHandler(error); return }
                guard !cancelled else { completionHandler(NSError(domain:"PhoneHistory",code:9,userInfo:[NSLocalizedDescriptionKey:"Capture start was cancelled."])); return }
                self.readPackets()
                registerHistoryProvider(self)
                phone_history_set_tunnel_connector(historyTunnelConnect)
                phone_history_set_vision_reader(historyRecognizeFrame)
                let history = folder.appendingPathComponent("Records", isDirectory: true)
                let status = folder.appendingPathComponent("status.json")
                let worker = Thread { [weak self] in
                    let pointer = pairing.path.withCString { pair in history.path.withCString { output in
                        status.path.withCString { phone_history_run_background(pair,output,$0) }
                    }}
                    if let pointer {
                        let data = Data(String(cString:pointer).utf8)
                        phone_history_free(pointer)
                        try? data.write(to: folder.appendingPathComponent("last-exit.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
                        if let result = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any], result["ok"] as? Bool == false {
                            let failure:[String:Any] = ["state":"failed","updated_at":Date().timeIntervalSince1970,
                                "runtime":"packet_tunnel_provider","complete_screen":false]
                            if let diagnostic = try? JSONSerialization.data(withJSONObject:failure) {
                                try? diagnostic.write(to:status,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
                            }
                        }
                    }
                    // A dead reader must not leave an apparently connected VPN.
                    // Let the system reconnect through the configured on-demand rule.
                    if let self,!self.isStopped,options?["trialSeconds"] == nil {
                        self.cancelTunnelWithError(NSError(domain:"PhoneHistory",code:10,userInfo:[NSLocalizedDescriptionKey:"The capture worker exited. Reconnect capture to resume."]))
                    }
                }
                worker.stackSize = 8*1024*1024
                worker.qualityOfService = .utility
                self.worker = worker
                worker.start()
                let engine=MemoryEngine(folder:folder,submit:{row in row.withCString {phone_history_submit_memory($0)==1}})
                self.memoryEngine=engine;Task { await engine.start() }
                let desktopServer = DesktopExportServer(folder:folder,manualRead: {
                    guard let pointer=phone_history_check_now() else { return ["available":false] }
                    defer { phone_history_free(pointer) }
                    guard let data=String(cString:pointer).data(using:.utf8),
                        let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],value["ok"] as? Bool == true,
                        let result=value["result"] as? [String:Any] else { return ["available":false,"reason":"worker_timeout_or_unavailable","stored":false] }
                    return result
                },screenshotRead: {
                    guard let pointer=phone_history_screenshot_now() else { return ["available":false,"stored":false] }
                    defer { phone_history_free(pointer) }
                    guard let data=String(cString:pointer).data(using:.utf8),
                        let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],value["ok"] as? Bool == true,
                        var result=value["result"] as? [String:Any] else { return ["available":false,"reason":"worker_timeout_or_unavailable","stored":false] }
                    guard result["available"] as? Bool == true else { return result }
                    // Bound transfer and memory cost. No image is written to disk.
                    guard let encoded=result["data"] as? String,let png=Data(base64Encoded:encoded),png.count<=8*1024*1024,
                        let source=CGImageSourceCreateWithData(png as CFData,nil),
                        let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
                            kCGImageSourceThumbnailMaxPixelSize:2048,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary)
                    else { return ["available":false,"reason":"invalid_screenshot","stored":false] }
                    let jpeg=NSMutableData()
                    guard let destination=CGImageDestinationCreateWithData(jpeg,UTType.jpeg.identifier as CFString,1,nil) else { return ["available":false,"stored":false] }
                    CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.8] as CFDictionary)
                    guard CGImageDestinationFinalize(destination),jpeg.length<=1024*1024 else { return ["available":false,"reason":"image_size_limit","stored":false] }
                    result["data"]=(jpeg as Data).base64EncodedString();result["mime_type"]="image/jpeg"
                    result["width"]=image.width;result["height"]=image.height;result["bytes"]=jpeg.length
                    return result
                },manualSummary: {
                    Task {await engine.force()}
                    return ["queued":true,"window_seconds":600]
                })
                self.desktopServer = desktopServer
                desktopServer.update()
                if let seconds = options?["trialSeconds"] as? NSNumber {
                    DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+seconds.doubleValue) { [weak self] in
                        guard let self, !self.isStopped else { return }
                        phone_history_stop()
                        // A finite validation option only. Normal Start history
                        // has no timer and remains active until the user stops.
                    }
                }
                CaptureControlState.update(enabled: true)
                completionHandler(nil)
            }
        } catch { lock.lock(); starting = false; lock.unlock(); completionHandler(error) }
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func readPackets() {
        guard !isStopped else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, !self.isStopped else { return }
            var reflected: [Data] = []
            for (packet, family) in zip(packets, protocols) {
                guard family.int32Value == AF_INET, packet.count >= 20, packet[0] >> 4 == 4 else { continue }
                var data = packet
                // Swapping source/destination preserves both the IPv4 header
                // and transport pseudo-header checksums (the sums are equal).
                let source = Array(data[12..<16]); let destination = Array(data[16..<20])
                guard source == [10,7,1,1], destination == [10,7,0,1] else { continue }
                data.replaceSubrange(12..<16,with:destination)
                data.replaceSubrange(16..<20,with:source)
                reflected.append(data)
            }
            if !reflected.isEmpty { self.packetFlow.writePackets(reflected,withProtocols:Array(repeating:NSNumber(value:AF_INET),count:reflected.count)) }
            self.readPackets()
        }
    }
    func openTunnelConnection(host: String, port: UInt16) -> Int32 {
        guard host == "10.7.0.1", !isStopped else { return -1 }
        var descriptors: [Int32] = [-1,-1]
        guard Darwin.socketpair(AF_UNIX,SOCK_STREAM,0,&descriptors) == 0 else { return -1 }
        var noSignal: Int32 = 1
        setsockopt(descriptors[0],SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptors[1],SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
        let endpoint = NWHostEndpoint(hostname:host,port:String(port))
        let connection = createTCPConnectionThroughTunnel(to:endpoint,enableTLS:false,tlsParameters:nil,delegate:nil)
        let bridge = TunnelConnection(connection:connection,descriptor:descriptors[1]) { [weak self] id in
            guard let self else { return }
            self.lock.lock(); self.connections.removeValue(forKey:id); self.lock.unlock()
        }
        lock.lock()
        if stopped { lock.unlock(); bridge.cancel(); Darwin.close(descriptors[0]); return -1 }
        connections[bridge.id] = bridge; lock.unlock()
        bridge.activate()
        return descriptors[0]
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lock.lock(); stopped = true; starting = false; let current = Array(connections.values); connections.removeAll(); lock.unlock()
        if let folder=try? HistoryPaths.folder(),let data=try? JSONSerialization.data(withJSONObject:["reason":reason.rawValue,"reason_name":String(describing:reason),"stopped_at":Date().timeIntervalSince1970]) {
            try? data.write(to:folder.appendingPathComponent("last-stop.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        }
        CaptureControlState.update(enabled: false)
        phone_history_stop()
        if let engine=memoryEngine { Task { await engine.stop() } };memoryEngine=nil
        desktopServer?.stop(); desktopServer = nil
        for connection in current { connection.cancel() }
        completionHandler()
    }
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if String(data:messageData,encoding:.utf8) == "desktop-access-changed" {
            desktopServer?.update(); completionHandler?(Data("ok".utf8))
        } else if String(data:messageData,encoding:.utf8) == "summarize-now" {
            if let engine=memoryEngine { Task { await engine.force() } };completionHandler?(Data("queued".utf8))
        } else if String(data:messageData,encoding:.utf8) == "status", let folder = try? HistoryPaths.folder() {
            completionHandler?(try? Data(contentsOf:folder.appendingPathComponent("status.json")))
        } else { completionHandler?(nil) }
    }
}
