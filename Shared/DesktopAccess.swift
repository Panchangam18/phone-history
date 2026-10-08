import Foundation
import CryptoKit
import Security

struct DesktopPair: Codable {
    let id: String
    let name: String
    let publicKey: String
    let approvedAt: Double
    var allowsScreenshots: Bool = false
    enum CodingKeys:String,CodingKey { case id,name,publicKey,approvedAt,allowsScreenshots }
    init(id:String,name:String,publicKey:String,approvedAt:Double,allowsScreenshots:Bool=false) {
        self.id=id;self.name=name;self.publicKey=publicKey;self.approvedAt=approvedAt;self.allowsScreenshots=allowsScreenshots
    }
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id);name=try c.decode(String.self,forKey:.name)
        publicKey=try c.decode(String.self,forKey:.publicKey);approvedAt=try c.decode(Double.self,forKey:.approvedAt)
        allowsScreenshots=try c.decodeIfPresent(Bool.self,forKey:.allowsScreenshots) ?? false
    }
}

struct DesktopAccessState: Codable {
    var privateKey: String
    var pairs: [DesktopPair]
}

enum DesktopAccess {
    static let protocolName = "phone-history-export-v1"
    static let port: UInt16 = 9876
    static func stateURL(_ folder: URL) -> URL { folder.appendingPathComponent("desktop-access.json") }
    static func load(_ folder: URL) throws -> DesktopAccessState {
        let url = stateURL(folder)
        if FileManager.default.fileExists(atPath:url.path) {
            var state=try JSONDecoder().decode(DesktopAccessState.self,from:Data(contentsOf:url))
            #if os(iOS) && !targetEnvironment(simulator)
            if state.privateKey == "apple-keychain" { state.privateKey=try identityKey().base64EncodedString() }
            else { try save(state,folder:folder) } // Verify migration before removing the legacy file key.
            #endif
            return state
        }
        return DesktopAccessState(privateKey:Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString(),pairs:[])
    }
    static func save(_ value: DesktopAccessState, folder: URL) throws {
        var stored=value
        #if os(iOS) && !targetEnvironment(simulator)
        let raw=try privateKey(value).rawRepresentation
        try storeIdentity(raw)
        guard try identityKey() == raw else { throw AccessError.invalidKey }
        stored.privateKey="apple-keychain"
        #endif
        try JSONEncoder().encode(stored).write(to:stateURL(folder),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:stateURL(folder).path)
    }
    static var keyStorage:String {
        #if os(iOS) && !targetEnvironment(simulator)
        return "apple_keychain_this_device_only"
        #else
        return "private_test_file"
        #endif
    }
    #if os(iOS) && !targetEnvironment(simulator)
    private static func identityQuery() -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"PhoneHistory.DesktopExport",
         kSecAttrAccount as String:"identity-v1",kSecAttrAccessGroup as String:BuildConfiguration.group]
    }
    private static func identityKey() throws -> Data {
        var query=identityQuery();query[kSecReturnData as String]=true;query[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess,let data=result as? Data,data.count==32 else { throw AccessError.invalidKey }
        return data
    }
    private static func storeIdentity(_ data:Data) throws {
        var query=identityQuery();query[kSecValueData as String]=data
        query[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result=SecItemAdd(query as CFDictionary,nil)
        guard result == errSecSuccess || result == errSecDuplicateItem else { throw AccessError.invalidKey }
    }
    #endif
    static func privateKey(_ value: DesktopAccessState) throws -> Curve25519.KeyAgreement.PrivateKey {
        guard let data = Data(base64Encoded:value.privateKey) else { throw AccessError.invalidKey }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation:data)
    }
    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    static func key(state: DesktopAccessState, pair: DesktopPair) throws -> SymmetricKey {
        guard let data = Data(base64Encoded:pair.publicKey) else { throw AccessError.invalidKey }
        let shared = try privateKey(state).sharedSecretFromKeyAgreement(with:Curve25519.KeyAgreement.PublicKey(rawRepresentation:data))
        return shared.hkdfDerivedSymmetricKey(using:SHA256.self,salt:Data(pair.id.utf8),
            sharedInfo:Data(protocolName.utf8),outputByteCount:32)
    }
    enum AccessError: Error { case invalidKey, unauthorized, invalidRequest, expired, replayed }
}

// The enclosing packet-tunnel provides runtime, not access authorization.
// Only phone-approved desktop keys can decrypt a response or submit a request.
final class DesktopExportProtocol {
    let folder: URL
    private var seen: [String:Double] = [:]
    private var lastRead: [String:Double] = [:]
    var screenshotRead:(()->[String:Any])?
    var manualRead:(()->[String:Any])?
    var manualSummary:(()->[String:Any])?
    init(folder: URL) { self.folder = folder }

    // Called on the export server's single serial queue.
    func respond(_ body: Data, now: Double = Date().timeIntervalSince1970) throws -> Data {
        guard body.count <= 8192,
              let envelope = try JSONSerialization.jsonObject(with:body) as? [String:Any],
              let id = envelope["pair_id"] as? String,
              let encoded = envelope["sealed"] as? String,
              let sealed = Data(base64Encoded:encoded) else { throw DesktopAccess.AccessError.invalidRequest }
        let state = try DesktopAccess.load(folder)
        guard let pair = state.pairs.first(where:{$0.id == id}) else { throw DesktopAccess.AccessError.unauthorized }
        let key = try DesktopAccess.key(state:state,pair:pair)
        let requestData = try AES.GCM.open(AES.GCM.SealedBox(combined:sealed),using:key,
            authenticating:Data((DesktopAccess.protocolName+":request").utf8))
        guard let request = try JSONSerialization.jsonObject(with:requestData) as? [String:Any],
              let requestID = request["request_id"] as? String, UUID(uuidString:requestID) != nil,
              let issued = request["issued_at"] as? Double,
              let operation = request["operation"] as? String, (["history","status","ax_check","screenshot","memories","evidence","summarize"]+HistoryOffload.operations).contains(operation)
        else { throw DesktopAccess.AccessError.invalidRequest }
        guard operation != "screenshot" || pair.allowsScreenshots else { throw DesktopAccess.AccessError.unauthorized }
        guard issued.isFinite,now.isFinite,abs(now-issued) <= 60 else { throw DesktopAccess.AccessError.expired }
        let replayURL=folder.appendingPathComponent("desktop-request-state.json")
        if FileManager.default.fileExists(atPath:replayURL.path) {
            let state=try JSONSerialization.jsonObject(with:Data(contentsOf:replayURL)) as? [String:Any]
            guard let ids=state?["seen"] as? [String:Double],let reads=state?["lastRead"] as? [String:Double] else { throw DesktopAccess.AccessError.invalidRequest }
            seen=ids;lastRead=reads
        }
        seen = seen.filter { $0.value > now-120 }
        let replayKey = id+":"+requestID
        guard seen.count < 1024,seen[replayKey] == nil else { throw DesktopAccess.AccessError.replayed }
        seen[replayKey] = now
        // Status followed by history is a normal agent flow. Throttle costly
        // history reads separately from the small freshness/status response.
        let readKey=(["ax_check","screenshot","summarize"].contains(operation)) ? "global:"+operation:id+":"+operation
        let interval: Double=operation == "summarize" ? 60 : (["history","memories","evidence"].contains(operation) ? 10 : (operation == "status" ? 2 : (["ax_check","screenshot"].contains(operation) ? 30 : 0)))
        guard now-(lastRead[readKey] ?? 0) >= interval else { throw DesktopAccess.AccessError.invalidRequest }
        lastRead[readKey] = now
        lastRead=lastRead.filter { $0.value>now-120 }
        try JSONSerialization.data(withJSONObject:["seen":seen,"lastRead":lastRead]).write(to:replayURL,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:replayURL.path)
        var response: [String:Any] = ["schema":1,"request_id":requestID,"generated_at":now,
            "coverage":"sampled, partial text context; not taps, typing, or proof of an action",
            "content_is_untrusted":true,"identity_key_storage":DesktopAccess.keyStorage]
        if HistoryOffload.operations.contains(operation) {
            let result=try HistoryOffload.respond(operation,request:request,pair:pair,folder:folder,now:now)
            for (key,value) in result { response[key]=value }
            let plain=try JSONSerialization.data(withJSONObject:response)
            return try JSONSerialization.data(withJSONObject:["pair_id":id,"sealed":AES.GCM.seal(plain,using:key,authenticating:Data((DesktopAccess.protocolName+":response").utf8)).combined!.base64EncodedString()])
        }
        if operation == "screenshot" {
            response["coverage"]="One point-in-time screenshot; protected content may be omitted. Not stored in phone history."
            response["screenshot"]=screenshotRead?() ?? ["available":false,"reason":"capture_worker_unavailable","stored":false]
        }
        if operation == "ax_check" {
            response["ax_check"]=manualRead?() ?? ["available":false,"reason":"capture_worker_unavailable","stored":false]
        }
        if operation == "summarize" {
            response["summary_request"]=manualSummary?() ?? ["queued":false,"reason":"capture_worker_unavailable"]
            response["coverage"]="Manual on-device summary of saved evidence from the preceding ten minutes; queued is not completion. No fresh screen capture or phone input."
        }
        let statusURL = folder.appendingPathComponent("status.json")
        if let data = try? Data(contentsOf:statusURL), let raw = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
            // Do not expose developer addresses, identities, diagnostics or trust.
            let keys = ["state","updated_at","samples","events_today","bytes_today","seconds","sampling_interval_seconds","ocr_reads","ocr_fallbacks","capture_source","resources",
                "fresh_walks_this_connection","capped_walks_this_connection","last_frontier_pending","rpc_calls","recorder_foreground"]
            var status = [String:Any]()
            for key in keys { if let value = raw[key] { status[key] = value } }
            response["capture"] = status
        }
        if let data=try? Data(contentsOf:folder.appendingPathComponent("memory-status.json")),let raw=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
            var safe:[String:Any]=[:]
            for key in ["state","updated_at","model_available","availability","scope","source_count","last_generated_at","evidence_preserved","next_window_end","summary_style","generation_failure"] {if let v=raw[key] {safe[key]=v}}
            response["memory_generation"]=safe
        }
        if ["history","memories","evidence"].contains(operation) {
            let since = (request["since"] as? Double) ?? now-86400
            guard since.isFinite, since >= now-7*86400, since <= now else { throw DesktopAccess.AccessError.invalidRequest }
            let limit = min(operation == "memories" ? 20:100,max(1,(request["limit"] as? Int) ?? 30))
            let records = folder.appendingPathComponent("Records",isDirectory:true)
            let names = (try? FileManager.default.contentsOfDirectory(at:records,includingPropertiesForKeys:nil)) ?? []
            let files = names.filter { url in
                let name = url.lastPathComponent
                guard name.hasPrefix("history-"), name.hasSuffix(".jsonl"),
                      let day = StoragePolicy.day(name) else { return false }
                return (day+1)*86400 > since && day*86400 <= now
            }
            let result:HistoryReadResult
            if operation == "evidence" {
                guard let ids=request["ids"] as? [String],!ids.isEmpty,ids.count<=40,ids.allSatisfy({!$0.isEmpty && $0.utf8.count<=80}) else {throw DesktopAccess.AccessError.invalidRequest}
                let wanted=Set(ids)
                let all=try HistoryReader.readNewest(files,limit:20000,since:Date(timeIntervalSince1970:since),kind:"all",includeNoise:true)
                result=HistoryReadResult(entries:all.entries.filter{wanted.contains($0.id)},skippedRows:all.skippedRows)
                response["missing_ids"]=ids.filter{id in !result.entries.contains{$0.id==id}}
            } else {result=try HistoryReader.readNewest(files,limit:operation == "memories" ? min(20,limit):limit,since:Date(timeIntervalSince1970:since),kind:operation == "memories" ? "memories":"evidence")}
            response["entries"] = result.entries.map {
                if let memory=$0.memory,let data=try? JSONEncoder().encode(memory),let row=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {return row}
                return ["timestamp":$0.date.timeIntervalSince1970,"app_label":$0.label,"text":$0.text,"id":$0.id,"source":$0.source,"partial":true,"host_app_identity_verified":$0.appIdentityVerified] as [String:Any]
            }
            if operation == "memories" {response["coverage"]="AI-generated summaries of partial observations. Source IDs reference bounded evidence; no proof of actions or intent."}
            response["skipped_rows"] = result.skippedRows
            response["limit"] = limit
            response["returned"] = result.entries.count
            response["order"] = "newest first"
            response["limit_reached"] = result.entries.count == limit
        }
        let plain = try JSONSerialization.data(withJSONObject:response,options:[.sortedKeys])
        let result = try AES.GCM.seal(plain,using:key,authenticating:Data((DesktopAccess.protocolName+":response").utf8))
        return try JSONSerialization.data(withJSONObject:["sealed":result.combined!.base64EncodedString()])
    }
}
