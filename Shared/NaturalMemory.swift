import Foundation

struct MemoryDraft:Sendable {
    let title:String
    let summary:String
    let quotes:[String]
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
        return lines.map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
    }
    static func representative(_ entries:[HistoryEntry],limit:Int=24)->[HistoryEntry] {
        let values=entries.filter{!clean($0).isEmpty}.sorted{$0.date<$1.date}
        guard values.count>limit,limit>1 else {return values}
        return (0..<limit).map{values[$0*(values.count-1)/(limit-1)]}
    }
    static func excerpts(_ entries:[HistoryEntry])->[MemoryExcerpt] {
        var seen=Set<String>()
        let values=representative(entries).compactMap{entry -> (String,HistoryEntry)? in
            let text=clean(entry).joined(separator:" ")
            guard seen.insert(entry.label+"|"+text).inserted else {return nil}
            return (text,entry)
        }
        // Allocate context across the chronological samples, without choosing
        // subjects, outcomes or verbs in code. The model interprets the text.
        let share=min(480,max(1,5800/max(1,values.count)-100))
        return values.enumerated().map{MemoryExcerpt(number:$0.offset+1,
            text:MemoryText.bounded($0.element.0,bytes:share),entry:$0.element.1)}
    }
    static func excerptPrompt(_ excerpts:[MemoryExcerpt])->String {
        let time=ISO8601DateFormatter()
        return excerpts.map{item in
            let label=ContextText.usefulLabel(item.entry.label) ? item.entry.label:"unknown"
            return "[\(item.number)] Time: \(time.string(from:item.entry.date)). Process: \(MemoryText.bounded(label,bytes:80)). Content: \(item.text)"
        }.joined(separator:"\n")
    }
    static func grounded(title:String,summary:String,references:[Int],excerpts:[MemoryExcerpt])->MemoryDraft? {
        let support=references.map{number in MemorySupport(excerpt:number,
            quote:excerpts.first(where:{$0.number==number}).map{MemoryText.bounded($0.text,bytes:240)} ?? "")}
        return grounded(title:title,summary:summary,support:support,excerpts:excerpts)
    }
    static func grounded(title:String,summary:String,support:[MemorySupport],excerpts:[MemoryExcerpt])->MemoryDraft? {
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.utf8.count<=160,
              !summary.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,summary.utf8.count<=1000,
              !support.isEmpty,support.count<=4 else {return nil}
        var quotes:[String]=[]
        for item in support {
            guard !item.quote.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,item.quote.utf8.count<=240,
                  let source=excerpts.first(where:{$0.number==item.excerpt}),source.text.contains(item.quote) else {return nil}
            if !quotes.contains(item.quote) {quotes.append(item.quote)}
        }
        // Quote occurrence is checked, not the semantic truth of the model's
        // interpretation. Preserve the model's prose without sentence rewriting.
        return MemoryDraft(title:title,summary:summary,quotes:quotes)
    }
}
