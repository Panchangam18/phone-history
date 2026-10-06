import Foundation

// These operations are deliberately absent from the read-only MCP tools.
// A dedicated authenticated receiver announces itself; removal additionally
// requires selecting that exact desktop in the phone's storage settings.
enum HistoryOffload {
    static let operations=["receiver_poll","offload_chunk","offload_ack"]
    static func respond(_ operation:String, request:[String:Any], pair:DesktopPair, folder:URL, now:Double) throws -> [String:Any] {
        if operation == "receiver_poll" {
            try JSONSerialization.data(withJSONObject:["pair_id":pair.id,"seen_at":now]).write(to:folder.appendingPathComponent("active-receiver.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        }
        let policy=try StoragePolicy.load(folder)
        guard policy.mode == .send,policy.receiverID == pair.id else {
            if operation == "receiver_poll" { return ["receiver_ready":true,"offload_selected":false] }
            throw DesktopAccess.AccessError.unauthorized
        }
        let records=folder.appendingPathComponent("Records")
        // Current-day history-N.jsonl is owned by the writer and never sent
        // for removal. Rotation creates immutable, standalone dictionary sessions.
        let day=Int(now/86400)
        let files=StoragePolicy.historyFiles(folder).filter { url in
            url.lastPathComponent != "history-\(day).jsonl"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if operation == "receiver_poll" {
            if let file=files.first {
                let bytes=(try file.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
                guard bytes <= 4*1024*1024 else { throw DesktopAccess.AccessError.invalidRequest }
                return ["receiver_ready":true,"offload_selected":true,"segment":["name":file.lastPathComponent,"bytes":bytes,"sha256":try StoragePolicy.hash(file)]]
            }
            let active=records.appendingPathComponent("history-\(day).jsonl")
            let bytes=(try? active.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
            // Do not turn idle headers into a stream of tiny transfer segments.
            if bytes > 256 && !FileManager.default.fileExists(atPath:folder.appendingPathComponent("rotate-history.json").path) {
                try JSONSerialization.data(withJSONObject:["id":UUID().uuidString]).write(to:folder.appendingPathComponent("rotate-history.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            }
            return ["receiver_ready":true,"offload_selected":true,"preparing":bytes>256]
        }
        guard let name=request["name"] as? String, let file=files.first(where:{$0.lastPathComponent == name}),
              !((try file.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink ?? true) else { throw DesktopAccess.AccessError.invalidRequest }
        if operation == "offload_chunk" {
            guard let offset=request["offset"] as? Int,offset >= 0,
                  let bytes=(try file.resourceValues(forKeys:[.fileSizeKey])).fileSize,bytes <= 4*1024*1024,offset <= bytes else { throw DesktopAccess.AccessError.invalidRequest }
            let handle=try FileHandle(forReadingFrom:file);defer { try? handle.close() };try handle.seek(toOffset:UInt64(offset))
            let data=try handle.read(upToCount:65536) ?? Data()
            return ["name":name,"offset":offset,"data":data.base64EncodedString(),"bytes":bytes]
        }
        guard operation == "offload_ack",let digest=request["sha256"] as? String,digest == (try StoragePolicy.hash(file)) else { throw DesktopAccess.AccessError.invalidRequest }
        // Confirmed hash applies to an immutable file, never a prefix of the
        // active log. A timeout or disconnect before this request deletes nothing.
        try FileManager.default.removeItem(at:file)
        try JSONSerialization.data(withJSONObject:["pair_id":pair.id,"name":name,"saved_sha256":digest,"acknowledged_at":now]).write(to:folder.appendingPathComponent("last-offload.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        return ["removed":name,"acknowledged":true]
    }
}
