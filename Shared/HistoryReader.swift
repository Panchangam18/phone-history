import Foundation
import CryptoKit

struct HistoryEntry: Sendable {
    let date: Date
    let label: String
    let text: [String]
    var id:String = ""
    var source:String = "AX"
    var memory:MemoryRecord? = nil
}

struct HistoryReadResult: Sendable {
    let entries: [HistoryEntry]
    let skippedRows: Int
}

enum HistoryReader {
    private struct State { var label = ""; var text: [String] = []; var dictionary: [String] = [] }

    // Resolve only the requested references. Reconstruct delta state in order,
    // but do not retain or hash thousands of unrelated observations.
    static func readIDs(_ files:[URL],ids:Set<String>) throws -> HistoryReadResult {
        var remaining=ids;var entries:[HistoryEntry]=[];var skipped=0
        for file in files.sorted(by:{$0.lastPathComponent > $1.lastPathComponent}) {
            try Task.checkCancellation()
            guard !remaining.isEmpty else {break}
            let result=try read([file],limit:remaining.count,includeNoise:true,ids:remaining)
            entries+=result.entries;skipped+=result.skippedRows
            remaining.subtract(result.entries.map{$0.id})
        }
        return HistoryReadResult(entries:entries.sorted{$0.date>$1.date},skippedRows:skipped)
    }

    static func readNewest(_ files:[URL],limit:Int=100,since:Date?=nil,kind:String="all",includeNoise:Bool=false) throws -> HistoryReadResult {
        var entries:[HistoryEntry]=[];var skipped=0
        for file in files.sorted(by:{
            let a=Double($0.lastPathComponent.dropFirst(8).split(separator:"-").first?.split(separator:".").first ?? "") ?? 0,b=Double($1.lastPathComponent.dropFirst(8).split(separator:"-").first?.split(separator:".").first ?? "") ?? 0
            return a == b ? $0.lastPathComponent > $1.lastPathComponent:a>b
        }) {
            try Task.checkCancellation()
            let result=try read([file],limit:max(1,limit-entries.count),since:since,kind:kind,includeNoise:includeNoise)
            entries+=result.entries;skipped+=result.skippedRows
            if entries.count>=limit { break }
        }
        return HistoryReadResult(entries:Array((kind == "memories" ? distinctWindows(entries):entries).prefix(limit)),skippedRows:skipped)
    }
    private static func distinctWindows(_ entries:[HistoryEntry])->[HistoryEntry] {
        var seen=Set<String>()
        return entries.sorted{($0.memory?.generatedAt ?? 0)>($1.memory?.generatedAt ?? 0)}.filter {
            guard let m=$0.memory else {return false}
            return seen.insert(m.scope+"|"+String(Int(m.start))).inserted
        }.sorted{$0.date>$1.date}
    }
    static func read(_ files: [URL], limit: Int = 100, since: Date? = nil,kind:String="all",includeNoise:Bool=false,ids:Set<String>?=nil) throws -> HistoryReadResult {
        var entries: [HistoryEntry] = []
        var skipped = 0
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            var states: [Int:State] = [:]
            var version = 0
            var epoch: Double = 0
            let cursorURL=file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("memory-cursor.json")
            let cursor=(try? JSONSerialization.jsonObject(with:Data(contentsOf:cursorURL))) as? [String:Double] ?? [:]
            let data = try Data(contentsOf: file)
            for line in data.split(separator: 10) {
                try Task.checkCancellation()
                guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String:Any] else { skipped += 1; continue }
                if row["kind"] as? String == "memory" {
                    if let ids,let id=row["id"] as? String,!ids.contains(id) {continue}
                    guard let memory=MemoryRecord.decode(row) else {skipped+=1;continue}
                    if kind == "memories" {
                        if (memory.format ?? 0) < 8 {continue}
                        // A later model abstention supersedes an older generated
                        // memory in this view. Original records remain by ID.
                        let abstained=cursor["abstained_"+memory.scope+"_"+String(Int(memory.start))] ?? 0
                        if (cursor["format_revision"] ?? 0)>Double(memory.format ?? 0),abstained>=memory.end {continue}
                    }
                    if kind != "evidence",since == nil || memory.end>=since!.timeIntervalSince1970 {
                        entries.append(HistoryEntry(date:Date(timeIntervalSince1970:memory.end),label:memory.apps.joined(separator:", "),text:[memory.summary]+memory.facts,id:memory.id,source:"AI summary",memory:memory))
                    }
                    continue
                }
                if kind == "memories" {continue}
                if let value = row["v"] as? Int {
                    version = value; epoch = (row["t"] as? NSNumber)?.doubleValue ?? 0
                    states.removeAll(); continue
                }
                guard version == 1 || version == 2, let pid = row["p"] as? Int,
                      let seconds = row["s"] as? Int, seconds >= 0 && seconds < 86400 else { skipped += 1; continue }
                if row["reset"] as? Bool == true { states.removeAll() }
                var state = states[pid] ?? State()
                if let label = row["a"] as? String { state.label = label }
                let added = row["n"] as? [String] ?? []
                if version == 2 {
                    if row["reset_p"] as? Bool == true { state.dictionary.removeAll() }
                    state.dictionary.append(contentsOf: added)
                    if let selection = row["c"] as? [Int] {
                        guard selection.allSatisfy({ state.dictionary.indices.contains($0) }) else { skipped += 1; continue }
                        state.text = selection.map { state.dictionary[$0] }
                    } else if !added.isEmpty { state.text = added }
                } else {
                    for index in (row["r"] as? [Int] ?? []).sorted(by: >) where state.text.indices.contains(index) { state.text.remove(at:index) }
                    state.text = Array(Set(state.text + added)).sorted()
                }
                states[pid] = state
                guard !state.text.isEmpty,includeNoise || !ContextText.content(state.text).isEmpty else { continue }
                if let since, epoch+Double(seconds) < since.timeIntervalSince1970 { continue }
                if let ids,let id=row["id"] as? String,!ids.contains(id) {continue}
                let id:String
                if let stored=row["id"] as? String {id=stored}
                else {id="legacy-"+SHA256.hash(data:Data("\(pid)|\(epoch+Double(seconds))|\(state.text.joined(separator:"|"))".utf8)).map{String(format:"%02x",$0)}.joined()}
                if let ids,!ids.contains(id) {continue}
                entries.append(HistoryEntry(date:Date(timeIntervalSince1970:epoch+Double(seconds)),
                    label:state.label.isEmpty ? "App context" : state.label, text:state.text,id:id,source:row["source"] as? String ?? "AX"))
                if entries.count > max(1,limit)*2 { entries.removeFirst(entries.count-max(1,limit)) }
            }
        }
        let newest=Array(entries.suffix(max(1,limit)).reversed())
        return HistoryReadResult(entries:kind == "memories" ? distinctWindows(newest):newest,skippedRows:skipped)
    }
}
