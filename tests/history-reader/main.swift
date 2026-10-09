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
    ["s":8,"p":1,"reset":true,"a":"Restart","n":["New"],"host_app_identity_verified":true]
]
var fixture = Data()
for row in rows { fixture.append(try JSONSerialization.data(withJSONObject:row)); fixture.append(10) }
fixture.append(Data("{unfinished".utf8))
try fixture.write(to:path)
let read = try HistoryReader.read([path],includeNoise:true)
assert(read.skippedRows == 1)
assert(read.entries.count == 8)
assert(read.entries[0].label == "Restart" && read.entries[0].text == ["New"])
assert(read.entries[0].appIdentityVerified && !read.entries[1].appIdentityVerified)
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
    let row:[String:Any]=["s":index,"p":1,"id":"e-\(index)","n":[index == 0 ? "Unique older subject" : "Observation \(index)"],"reset_p":true]
    longFixture.append(try JSONSerialization.data(withJSONObject:row));longFixture.append(10)
}
try longFixture.write(to:longPath)
let oldest=try HistoryReader.readIDs([longPath],ids:["e-0","e-20004"])
assert(oldest.entries.map{$0.id} == ["e-20004","e-0"])
assert(oldest.entries.last!.text == ["Unique older subject"])
// Search filters reconstructed text before limiting; old matches survive even
// when newer unrelated rows greatly exceed the ordinary display cap.
let found=try HistoryReader.read([longPath],limit:1,kind:"evidence",query:"unique older")
assert(found.entries.map{$0.id} == ["e-0"])
let deltaMatch=try HistoryReader.read([path],limit:1,includeNoise:true,query:"page b shared")
assert(deltaMatch.entries.first!.text == ["Page B","Shared"])
let tiedPath=folder.appendingPathComponent("history-3.jsonl")
let overlappingPath=folder.appendingPathComponent("history-4.jsonl")
try Data("{\"v\":2,\"t\":300000}\n{\"s\":1,\"p\":1,\"id\":\"e-c\",\"n\":[\"Café launch\"]}\n{\"s\":1,\"p\":1,\"id\":\"e-a\"}\n".utf8).write(to:tiedPath)
try Data("{\"v\":2,\"t\":300000}\n{\"s\":1,\"p\":1,\"id\":\"e-b\",\"n\":[\"Café launch\"]}\n".utf8).write(to:overlappingPath)
let page1=try HistoryReader.read([tiedPath,overlappingPath],limit:2,ordered:true,query:"CAFE LAUNCH")
assert(page1.entries.map{$0.id} == ["e-c","e-b"])
let cursor=page1.entries.last!
let page2=try HistoryReader.read([tiedPath,overlappingPath],limit:2,ordered:true,before:cursor.date,beforeID:cursor.id,query:"cafe")
assert(page2.entries.map{$0.id} == ["e-a"])
let excludedTie=try HistoryReader.read([tiedPath],before:cursor.date)
assert(excludedTie.entries.isEmpty)
let boundedIDs=try HistoryReader.readIDs([path],ids:requested,since:Date(timeIntervalSince1970:86403))
assert(boundedIDs.entries.count == 1)
// Summary context keeps screen boundaries and meaningful lines, omitting an
// unverified process hint rather than attributing the text to a stale app.
let context=HistoryEntry(date:Date(timeIntervalSince1970:1000),label:"Stale process",text:["Follow","A post about orbital telescopes","Another author discusses coral reefs"],id:"e-context",source:"OCR")
let excerpts=NaturalMemory.excerpts([context])
let prompt=NaturalMemory.excerptPrompt(excerpts)
assert(!prompt.contains("Stale process") && !prompt.contains("1: Follow"))
assert(prompt.contains("1: A post about orbital telescopes\n2: Another author discusses coral reefs"))
let wrapped=HistoryEntry(date:context.date,label:"Context",text:["Questions to ask a potential","spouse."])
assert(NaturalMemory.clean(wrapped) == wrapped.text)
let draft=NaturalMemory.grounded(title:"Space and reefs",summary:"You browsed posts about orbital telescopes and coral reefs.",lines:[(1,1),(1,2)],excerpts:excerpts)!
assert(draft.quotes == ["A post about orbital telescopes","Another author discusses coral reefs"])
assert(draft.supportSources == ["e-context","e-context"])
assert(NaturalMemory.grounded(title:"Space",summary:"You browsed a post.",lines:[(1,99)],excerpts:excerpts) == nil)
let duplicates=(0..<30).map {HistoryEntry(date:Date(timeIntervalSince1970:Double($0)),label:"Context",text:["Repeated visible subject"],id:"e-repeat-\($0)")}
let ending=HistoryEntry(date:Date(timeIntervalSince1970:31),label:"Context",text:["A distinct result at the end"],id:"e-ending")
assert(NaturalMemory.representative(duplicates+[ending]).map{$0.id} == ["e-repeat-0","e-ending"])
let longScreens=(0..<12).map {HistoryEntry(date:Date(timeIntervalSince1970:Double($0)),label:"Context",text:["Screen \($0): "+String(repeating:"context ",count:200)],id:"e-long-\($0)")}
let boundedPrompt=NaturalMemory.excerptPrompt(NaturalMemory.excerpts(longScreens))
assert(boundedPrompt.utf8.count < 8000)
assert(NaturalMemory.excerpts(longScreens).allSatisfy{$0.text.utf8.count>240})
// A brief screen's title near the bottom must not be discarded while most
// other screens leave their equal shares of the context budget unused.
let shortScreens=(0..<11).map{HistoryEntry(date:Date(timeIntervalSince1970:Double($0)),label:"Context",text:["Short screen \($0)"])}
let titleAtEnd=HistoryEntry(date:Date(timeIntervalSince1970:12),label:"Context",text:[String(repeating:"Context line\n",count:45)+"Distinct title at the bottom"])
let redistributed=NaturalMemory.excerpts(shortScreens+[titleAtEnd])
assert(redistributed.last!.text.contains("Distinct title at the bottom"))
let oversized=HistoryEntry(date:Date(timeIntervalSince1970:12),label:"Context",text:["Beginning topic\n"+String(repeating:"Long context paragraph. ",count:500)+"\nEnding topic"])
let clipped=NaturalMemory.excerpts(shortScreens+[oversized]).last!.text
assert(clipped.contains("Beginning topic") && clipped.contains("Ending topic"))
assert(clipped.contains("[... omitted ...]"))
if CommandLine.arguments.count > 1 {
    let actual = try HistoryReader.read([URL(fileURLWithPath:CommandLine.arguments[1])])
    assert(actual.skippedRows == 0)
    print("Live mixed-version stream: \(actual.entries.count) readable entries; zero decoding errors.")
}
print("History reader checks passed: legacy sessions, dictionary references, reentry, resets, unfinished row and display limit.")
