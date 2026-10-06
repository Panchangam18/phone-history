import Foundation
import CryptoKit

let folder = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
let hello = try JSONSerialization.jsonObject(with:Data(readLine()!.utf8)) as! [String:Any]
let pair = DesktopPair(id:UUID().uuidString,name:"Test desktop",publicKey:hello["desktop_public_key"] as! String,approvedAt:Date().timeIntervalSince1970)
let state = DesktopAccessState(privateKey:Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString(),pairs:[pair])
try DesktopAccess.save(state,folder:folder)
let publicKey = try DesktopAccess.privateKey(state).publicKey.rawRepresentation.base64EncodedString()
let connection: [String:Any] = ["protocol":DesktopAccess.protocolName,"pair_id":pair.id,"phone_public_key":publicKey,"desktop_public_key":pair.publicKey,"host":"192.168.1.10","port":9876]
print(String(data:try JSONSerialization.data(withJSONObject:connection),encoding:.utf8)!); fflush(stdout)
if CommandLine.arguments.contains("--server") {
    let server = DesktopExportServer(folder:folder)
    server.update()
    RunLoop.current.run(until:Date().addingTimeInterval(30))
    server.stop()
    exit(0)
}
func configure(_ handler:DesktopExportProtocol) {
    handler.manualSummary={ ["queued":true,"window_seconds":600] }
    handler.screenshotRead={ ["available":true,"timestamp":Date().timeIntervalSince1970,"mime_type":"image/jpeg",
        "data":Data([0xff,0xd8,0xff,0xd9]).base64EncodedString(),"width":100,"height":200,"stored":false] }
}
var handler = DesktopExportProtocol(folder:folder)
configure(handler)
while let line = readLine() {
    do {
        let command = try JSONSerialization.jsonObject(with:Data(line.utf8)) as! [String:Any]
        if let rows=command["topics"] as? [[String:Any]],let content=command["content"] as? [String] {
            let entry=HistoryEntry(date:Date(),label:command["label"] as? String ?? "Fixture",text:content)
            let excerpts=NaturalMemory.excerpts([entry])
            let draft=NaturalMemory.compose(rows.map{MemoryTopic(subject:$0["subject"] as? String ?? "",excerpts:$0["excerpts"] as? [Int] ?? [],detail:$0["detail"] as? String ?? "")},excerpts:excerpts)
            let fallback=NaturalMemory.excerptFallback(excerpts)
            let output:[String:Any]=["accepted":draft != nil,"summary":draft?.summary ?? "","quotes":draft?.quotes ?? [],"fallback_summary":fallback?.summary ?? "","excerpts":excerpts.map{$0.text}]
            print(String(decoding:try JSONSerialization.data(withJSONObject:output),as:UTF8.self))
        }
        else if let draft=command["draft"] as? [String:Any],let content=command["content"] as? [String] {
            let entry=HistoryEntry(date:Date(),label:"",text:content)
            let value=MemoryDraft(title:draft["title"] as? String ?? "",summary:draft["summary"] as? String ?? "",quotes:draft["quotes"] as? [String] ?? [])
            let accepted=NaturalMemory.checked(value,entries:[entry]) != nil
            let fallback=NaturalMemory.fallback(value.quotes,entries:[entry])
            let output:[String:Any]=["accepted":accepted,"meaningful_count":ContextText.content(content).count,"fallback_title":fallback?.title ?? "","fallback_summary":fallback?.summary ?? "","prompt":NaturalMemory.prompt([entry])]
            print(String(decoding:try JSONSerialization.data(withJSONObject:output),as:UTF8.self))
        }
        else if command["recreate"] as? Bool == true { handler=DesktopExportProtocol(folder:folder);configure(handler);print("{\"recreated\":true}") }
        else if let allowed=command["allow_screenshots"] as? Bool { var state=try DesktopAccess.load(folder);state.pairs[0].allowsScreenshots=allowed;try DesktopAccess.save(state,folder:folder);print("{\"updated\":true}") }
        else if command["active_receiver"] as? Bool == true { print("{\"active\":\(StoragePolicy.activeReceiver(folder,now:command["now"] as! Double) != nil)}") }
        else if command["revoke"] as? Bool == true { var state = try DesktopAccess.load(folder); state.pairs = []; try DesktopAccess.save(state,folder:folder); print("{\"revoked\":true}") }
        else {
            let data = Data(base64Encoded:command["body"] as! String)!
            let result = try handler.respond(data,now:command["now"] as! Double)
            print(String(data:result,encoding:.utf8)!)
        }
    } catch { print("{\"denied\":true}") }
    fflush(stdout)
}
