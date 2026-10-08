import Foundation

let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:folder) }
let path = folder.appendingPathComponent("history-1.jsonl")
let rows: [[String:Any]] = [
    ["v":1,"t":86400], ["s":1,"p":1,"a":"Example","n":["Old"]],
    ["v":2,"t":86400], ["s":2,"p":1,"a":"Example","n":["Page A","Shared"]],
    ["s":3,"p":1,"n":["Page B"],"c":[2,1]],
    ["s":4,"p":2,"a":"Second","n":["Elsewhere"]], ["s":5,"p":1],
    ["s":6,"p":1,"c":[0,1]], ["s":7,"p":1,"reset_p":true,"n":["Fresh"]],
    ["s":8,"p":1,"reset":true,"a":"Restart","n":["New"]]
]
var fixture = Data()
for row in rows { fixture.append(try JSONSerialization.data(withJSONObject:row)); fixture.append(10) }
fixture.append(Data("{unfinished".utf8))
try fixture.write(to:path)
let read = try HistoryReader.read([path],includeNoise:true)
assert(read.skippedRows == 1)
assert(read.entries.count == 8)
assert(read.entries[0].label == "Restart" && read.entries[0].text == ["New"])
assert(read.entries[1].text == ["Fresh"])
assert(read.entries[2].text == ["Page A","Shared"])
assert(read.entries[3].text == ["Page B","Shared"])
assert(read.entries[5].text == ["Page B","Shared"])
assert(read.entries.last!.text == ["Old"])
let limited = try HistoryReader.read([path],limit:2,includeNoise:true)
assert(limited.entries.count == 2)
let requested=Set([read.entries[3].id,read.entries.last!.id,"expired-reference"])
let resolved=try HistoryReader.readIDs([path],ids:requested)
assert(resolved.entries.count == 2)
assert(resolved.entries[0].text == ["Page B","Shared"])
assert(resolved.entries[1].text == ["Old"])
// Named references must resolve beyond the old 20,000-item display cutoff.
let longPath=folder.appendingPathComponent("history-2.jsonl")
var longFixture=Data("{\"v\":2,\"t\":172800}\n".utf8)
for index in 0..<20005 {
    let row:[String:Any]=["s":index,"p":1,"id":"e-\(index)","n":["Observation \(index)"],"reset_p":true]
    longFixture.append(try JSONSerialization.data(withJSONObject:row));longFixture.append(10)
}
try longFixture.write(to:longPath)
let oldest=try HistoryReader.readIDs([longPath],ids:["e-0","e-20004"])
assert(oldest.entries.map{$0.id} == ["e-20004","e-0"])
assert(oldest.entries.last!.text == ["Observation 0"])
if CommandLine.arguments.count > 1 {
    let actual = try HistoryReader.read([URL(fileURLWithPath:CommandLine.arguments[1])])
    assert(actual.skippedRows == 0)
    print("Live mixed-version stream: \(actual.entries.count) readable entries; zero decoding errors.")
}
print("History reader checks passed: legacy sessions, dictionary references, reentry, resets, unfinished row and display limit.")
