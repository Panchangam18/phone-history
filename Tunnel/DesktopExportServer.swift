import Foundation
import Network
import Darwin

final class DesktopExportServer {
    private let queue = DispatchQueue(label:"PhoneHistory.DesktopExport",qos:.utility)
    private var listener: NWListener?
    private var connections: [UUID:NWConnection] = [:]
    private let protocolHandler: DesktopExportProtocol
    private let folder: URL
    init(folder: URL,manualRead:(()->[String:Any])? = nil,screenshotRead:(()->[String:Any])? = nil,manualSummary:(()->[String:Any])? = nil) { self.folder = folder; protocolHandler = DesktopExportProtocol(folder:folder);protocolHandler.manualRead=manualRead;protocolHandler.screenshotRead=screenshotRead;protocolHandler.manualSummary=manualSummary }
    func update() { queue.async { self.updateOnQueue() } }
    func stop() { queue.async { self.shutdown() } }
    private func shutdown() {
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        try? FileManager.default.removeItem(at:folder.appendingPathComponent("desktop-server.json"))
    }
    private func updateOnQueue() {
        guard let state = try? DesktopAccess.load(folder), !state.pairs.isEmpty else { shutdown(); return }
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .wifi
            let listener = try NWListener(using:parameters,on:NWEndpoint.Port(rawValue:DesktopAccess.port)!)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready: self.writeState("ready")
                case .failed: self.writeState("unavailable"); self.listener?.cancel(); self.listener = nil
                default: break
                }
            }
            listener.start(queue:queue)
        } catch { writeState("unavailable") }
    }
    private func writeState(_ state: String) {
        let object: [String:Any] = ["state":state,"port":DesktopAccess.port,"addresses":Self.wifiAddresses(),"updated_at":Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject:object) {
            try? data.write(to:folder.appendingPathComponent("desktop-server.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    static func wifiAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var result: [String] = []; var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString:entry.pointee.ifa_name) == "en0",
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating:0,count:Int(NI_MAXHOST))
            if getnameinfo(address,socklen_t(address.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST) == 0 {
                result.append(String(cString:host))
            }
        }
        return result
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 4 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state { case .failed,.cancelled: self?.connections.removeValue(forKey:id); default: break }
        }
        connection.start(queue:queue)
        queue.asyncAfter(deadline:.now()+5) { [weak self, weak connection] in
            connection?.cancel(); self?.connections.removeValue(forKey:id)
        }
        receive(connection,id:id,buffer:Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:12288) { [weak self] data,_,complete,error in
            guard let self, self.connections[id] != nil else { return }
            var buffer = buffer; if let data { buffer.append(data) }
            guard error == nil, buffer.count <= 12288 else { connection.cancel(); return }
            if let boundary = buffer.range(of:Data("\r\n\r\n".utf8)) {
                guard boundary.lowerBound <= 4096, let header = String(data:buffer[..<boundary.lowerBound],encoding:.utf8) else { self.reply(connection,status:400); return }
                let lines = header.components(separatedBy:"\r\n")
                guard lines.first == "POST /v1/export HTTP/1.1",
                      !lines.contains(where:{$0.lowercased().hasPrefix("transfer-encoding:")}) else { self.reply(connection,status:400); return }
                let lengths = lines.dropFirst().filter {$0.lowercased().hasPrefix("content-length:")}
                guard lengths.count == 1, let length = Int(lengths[0].split(separator:":",maxSplits:1)[1].trimmingCharacters(in:.whitespaces)), length > 0, length <= 8192 else { self.reply(connection,status:400); return }
                let body = buffer[boundary.upperBound...]
                if body.count == length {
                    do { self.reply(connection,status:200,body:try self.protocolHandler.respond(Data(body))) }
                    catch { self.reply(connection,status:403) }
                    return
                }
                if body.count > length { self.reply(connection,status:400); return }
            }
            guard !complete else { connection.cancel(); return }
            self.receive(connection,id:id,buffer:buffer)
        }
    }
    private func reply(_ connection: NWConnection, status: Int, body: Data = Data("{}".utf8)) {
        let text = status == 200 ? "OK" : "Denied"
        var data = Data("HTTP/1.1 \(status) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        connection.send(content:data,completion:.contentProcessed { _ in connection.cancel() })
    }
}
