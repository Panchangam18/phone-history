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
        if command["backup_policy"] as? Bool == true {
            let directory=folder.appendingPathComponent("backup-fixture",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let existing=directory.appendingPathComponent("history.txt")
            try Data("retained fixture".utf8).write(to:existing)
            try HistoryPaths.excludeFromBackup(directory)
            try HistoryPaths.excludeFromBackup(directory)
            let output:[String:Any]=["excluded":try directory.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup==true,
                "retained":try String(contentsOf:existing,encoding:.utf8)]
            print(String(decoding:try JSONSerialization.data(withJSONObject:output),as:UTF8.self))
        }
        else if let references=command["references"] as? [Int] {
            let entry=HistoryEntry(date:Date(timeIntervalSince1970:1000),label:"Fixture",text:["Your document was saved successfully"])
            let value=NaturalMemory.grounded(title:"Saved",summary:"You saved the document.",references:references,excerpts:NaturalMemory.excerpts([entry]))
            print(String(decoding:try JSONSerialization.data(withJSONObject:["accepted":value != nil,"summary":value?.summary ?? "","quotes":value?.quotes ?? []]),as:UTF8.self))
        }
        else if let draft=command["draft"] as? [String:Any],let content=command["content"] as? [String],let support=draft["evidence"] as? [[String:Any]] {
            let entry=HistoryEntry(date:Date(timeIntervalSince1970:1000),label:"Fixture",text:content)
            let excerpts=NaturalMemory.excerpts([entry])
            let value=NaturalMemory.grounded(title:draft["title"] as? String ?? "",summary:draft["summary"] as? String ?? "",
                support:support.map{MemorySupport(excerpt:$0["excerpt"] as? Int ?? 0,quote:$0["quote"] as? String ?? "")},excerpts:excerpts)
            let output:[String:Any]=["accepted":value != nil,"title":value?.title ?? "","summary":value?.summary ?? "","quotes":value?.quotes ?? [],"prompt":NaturalMemory.excerptPrompt(excerpts)]
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
