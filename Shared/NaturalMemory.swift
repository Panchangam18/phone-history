import Foundation

struct MemoryDraft:Sendable {
    let title:String
    let summary:String
    let quotes:[String]
    let supportSources:[String]
}

struct MemorySupport:Sendable {
    let excerpt:Int
    let quote:String
}

struct MemoryExcerpt:Sendable {
    let number:Int
    let text:String
    let entry:HistoryEntry
}

enum NaturalMemory {
    static func clean(_ entry:HistoryEntry)->[String] {
        let lines=entry.memory.map{[$0.title,$0.summary]+$0.facts} ?? entry.text
        return ContextText.summaryContent(lines.map{$0.trimmingCharacters(in:.whitespacesAndNewlines)})
    }
    static func representative(_ entries:[HistoryEntry],limit:Int=12)->[HistoryEntry] {
        var seen=Set<String>()
        let values=entries.sorted{$0.date<$1.date}.filter {
            let lines=clean($0)
            return !lines.isEmpty && seen.insert($0.source+"|"+lines.joined(separator:"\n")).inserted
        }
        guard values.count>limit,limit>1 else {return values}
        return (0..<limit).map{values[$0*(values.count-1)/(limit-1)]}
    }
    static func excerpts(_ entries:[HistoryEntry])->[MemoryExcerpt] {
        var seen=Set<String>()
        let values=representative(entries).compactMap{entry -> (String,HistoryEntry)? in
            let text=clean(entry).joined(separator:"\n")
            guard seen.insert(entry.label+"|"+text).inserted else {return nil}
            return (text,entry)
        }
        // Allocate context across the chronological samples, without choosing
        // subjects, outcomes or verbs in code. The model interprets the text.
        let budget=max(1,7800-values.count*140)
        // Short screens return unused context to longer screens. No subject
        // ranking: allocation depends only on byte length, not app or content.
        var allocations=Array(repeating:0,count:values.count)
        var remaining=budget
        var pending=Array(values.indices)
        while !pending.isEmpty && remaining>0 {
            let share=max(1,remaining/pending.count)
            let complete=pending.filter{min(2048,values[$0].0.utf8.count)<=share}
            if complete.isEmpty {
                for index in pending {allocations[index]=share}
                break
            }
            for index in complete {
                allocations[index]=min(2048,values[index].0.utf8.count)
                remaining-=allocations[index]
            }
            pending.removeAll{complete.contains($0)}
        }
        return values.enumerated().map{MemoryExcerpt(number:$0.offset+1,
            text:boundedScreen($0.element.0,bytes:allocations[$0.offset]),entry:$0.element.1)}
    }
    private static func boundedScreen(_ text:String,bytes:Int)->String {
        guard text.utf8.count>bytes else{return text}
        // Preserve both ends when a screen still exceeds its context share.
        // Explicit omission prevents the model reading the fragments as joined.
        let separator="\n[... omitted ...]\n"
        let available=max(0,bytes-separator.utf8.count)
        let head=MemoryText.bounded(text,bytes:available/2)
        let reversed=MemoryText.bounded(String(text.reversed()),bytes:available-available/2)
        return head+separator+String(reversed.reversed())
    }
    static func excerptPrompt(_ excerpts:[MemoryExcerpt])->String {
        let time=ISO8601DateFormatter()
        return excerpts.map{item in
            let label=ContextText.usefulLabel(item.entry.label) ? item.entry.label:"unknown"
            let identity=item.entry.appIdentityVerified ? " Verified app: \(MemoryText.bounded(label,bytes:80)).":""
            let lines=item.text.components(separatedBy:"\n").enumerated().map{"\($0.offset+1): \($0.element)"}.joined(separator:"\n")
            return "SCREEN [\(item.number)] Observed: \(time.string(from:item.entry.date)).\(identity) Source: \(item.entry.source).\n\(lines)\nEND SCREEN [\(item.number)]"
        }.joined(separator:"\n")
    }
    static func grounded(title:String,summary:String,lines:[(excerpt:Int,line:Int)],excerpts:[MemoryExcerpt])->MemoryDraft? {
        let support=lines.map { item -> MemorySupport in
            let source=excerpts.first{$0.number == item.excerpt}
            let lines=source?.text.components(separatedBy:"\n") ?? []
            let quote=lines.indices.contains(item.line-1) ? MemoryText.bounded(lines[item.line-1],bytes:240):""
            return MemorySupport(excerpt:item.excerpt,quote:quote)
        }
        return grounded(title:title,summary:summary,support:support,excerpts:excerpts)
    }
    static func grounded(title:String,summary:String,support:[MemorySupport],excerpts:[MemoryExcerpt])->MemoryDraft? {
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.utf8.count<=160,
              !summary.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,summary.utf8.count<=1000,
              !support.isEmpty,support.count<=4 else {return nil}
        var quotes:[String]=[];var sources:[String]=[]
        for item in support {
            guard !item.quote.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,item.quote.utf8.count<=240,
                  let source=excerpts.first(where:{$0.number==item.excerpt}),source.text.contains(item.quote) else {return nil}
            if !quotes.contains(item.quote) {quotes.append(item.quote);sources.append(source.entry.id)}
        }
        // Quote occurrence is checked, not the semantic truth of the model's
        // interpretation. Preserve the model's prose without sentence rewriting.
        return MemoryDraft(title:title,summary:summary,quotes:quotes,supportSources:sources)
    }
}
