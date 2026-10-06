import Foundation

struct MemoryDraft:Sendable {
    let title:String
    let summary:String
    let quotes:[String]
}

enum NaturalMemory {
    private static let connectiveWords=Set(["a","an","the","and","or","but","for","of","to","in","on","at","by","from","with","is","are","was","were","be","been","it","its","this","that","these","those","i","you","he","she","they","we","my","your","his","her","their","our","as","so","if","then","than","not","yes","yeah"])
    static func substantive(_ text:String)->Bool {
        // Digits inside a single OCR username must not turn it into two words.
        guard text.split(whereSeparator:{$0.isWhitespace}).filter({$0.contains(where:{$0.isLetter})}).count>=2 else {return false}
        let words=text.lowercased().split(whereSeparator:{!$0.isLetter}).map(String.init)
        return words.filter{!connectiveWords.contains($0) && $0.count>=3}.count>=2
    }
    static func clean(_ entry:HistoryEntry)->[String] {
        if let memory=entry.memory {return [memory.title,memory.summary]+memory.facts}
        return ContextText.content(entry.text).filter{$0.utf8.count>=12 && substantive($0)}
    }
    static func representative(_ entries:[HistoryEntry],limit:Int=24)->[HistoryEntry] {
        let values=entries.filter{!clean($0).isEmpty}.sorted{$0.date<$1.date}
        guard values.count>limit,limit>1 else {return values}
        return (0..<limit).map{values[$0*(values.count-1)/(limit-1)]}
    }
    static func prompt(_ entries:[HistoryEntry])->String {
        struct Block {var first:Date;var last:Date;let label:String;var lines:[String];var count:Int}
        var blocks:[Block]=[]
        for entry in entries.sorted(by:{$0.date<$1.date}) {
            let content=clean(entry)
            if let last=blocks.last,last.label==entry.label {
                blocks[blocks.count-1].last=entry.date;blocks[blocks.count-1].count+=1
                for line in content where !blocks[blocks.count-1].lines.contains(line) {blocks[blocks.count-1].lines.append(line)}
            } else {blocks.append(Block(first:entry.date,last:entry.date,label:entry.label,lines:content,count:1))}
        }
        let time=DateFormatter();time.dateFormat="HH:mm"
        let share=max(180,min(2400,5500/max(1,blocks.count)))
        return MemoryText.bounded(blocks.map{block in
            let label=ContextText.usefulLabel(block.label) ? "Observed process label: "+block.label:"App identity unavailable"
            return "Sequence segment \(time.string(from:block.first))–\(time.string(from:block.last)) (\(block.count) samples). \(label).\n"+balanced(block.lines,bytes:share)
        }.joined(separator:"\n\n"),bytes:6500)
    }
    private static func balanced(_ lines:[String],bytes:Int)->String {
        guard lines.joined(separator:"\n").utf8.count>bytes else {return lines.joined(separator:"\n")}
        var selected=Set<Int>();var used=0
        let corrections=lines.indices.filter{lines[$0].range(of:#"\b(?:typo|correction|corrected)\b"#,options:[.regularExpression,.caseInsensitive]) != nil}
        // Keep endpoints and explicit corrections, then cover the whole segment.
        let spread=(0..<min(24,lines.count)).map{$0*(lines.count-1)/max(1,min(24,lines.count)-1)}
        for index in ([0,lines.count-1]+corrections+spread) where !selected.contains(index) {
            let size=lines[index].utf8.count+1
            if used+size<=bytes {selected.insert(index);used+=size}
        }
        return selected.sorted().map{lines[$0]}.joined(separator:"\n")
    }
    static func checked(_ draft:MemoryDraft,entries:[HistoryEntry])->MemoryDraft? {
        let title=draft.title.trimmingCharacters(in:.whitespacesAndNewlines)
        let summary=draft.summary.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty,title.utf8.count<=160,!summary.isEmpty,summary.utf8.count<=1000 else {return nil}
        let text=entries.flatMap{clean($0)}
        let quotes=Array(Set(draft.quotes.map{$0.trimmingCharacters(in:.whitespacesAndNewlines)})).sorted().filter {
            $0.utf8.count>=12 && $0.utf8.count<=240 && substantive($0)
        }
        // Bind each supporting quote to actual content, not a provenance header.
        let supported=quotes.filter{quote in text.contains(where:{$0.contains(quote)})}
        guard !supported.isEmpty else {return nil}
        let lower=summary.lowercased()
        guard !lower.contains("observed screen text"),!lower.contains("screen text included"),!lower.contains("interact") else {return nil}
        let action=#"\b(?:messaged|sent|received|watched|typed|clicked|tapped|purchased|bought|paid|booked|scheduled|submitted|deleted|signed|approved|accepted|won|lost|played|listened|replied|liked|posted|shared|completed|finished|agreed|engaged|participated|commented|responded|networked|interested|wanted|decided|felt|believed|enjoyed)\b"#
        guard lower.range(of:action,options:.regularExpression)==nil else {return nil}
        let body=(text+entries.filter{ContextText.usefulLabel($0.label)}.map{$0.label}).joined(separator:" ").lowercased()
        // Dates, counts and times cannot be supplied from the model's knowledge.
        let digits=try! NSRegularExpression(pattern:#"\d+"#)
        let summaryNS=summary as NSString
        let bodyNS=body as NSString
        let recordedNumbers=Set(digits.matches(in:body,range:NSRange(location:0,length:bodyNS.length)).map{bodyNS.substring(with:$0.range)})
        guard digits.matches(in:summary,range:NSRange(location:0,length:summaryNS.length)).allSatisfy({recordedNumbers.contains(summaryNS.substring(with:$0.range))}) else {return nil}
        if lower.range(of:#"\b(?:messages?|conversation|chat|sender|recipient|comments?|replies|reply)\b"#,options:.regularExpression) != nil,
           body.range(of:#"\b(?:messages?|conversation|chat|comments?|replies|reply)\b"#,options:.regularExpression)==nil {return nil}
        // Reject invented named entities mid-sentence. A process label is evidence
        // of that process, not proof of a website or foreground host app.
        let canonical=body.filter{$0.isLetter || $0.isNumber}
        let regex=try! NSRegularExpression(pattern:#"\b[A-Z][a-zA-Z]{3,}\b"#)
        let ns=summary as NSString
        let common=Set(["The","This","That","Then","Next","Later","Earlier","During","Most","Some","Other","There","Content","Several","Screen","Text","Visible","Repeated","Repeatedly","Across","Only","After","Before","Browsing","Viewing","Both","Much","Various","Pages","Posts","Videos","Images","Articles","Topics","Discussion","Different","Additional","Overall","Initially","Finally","Meanwhile","Browsed","Checked","Explored","Reviewed","Read","Scrolled","Moved","Returned","Opened","Visited","Switched"])
        for match in regex.matches(in:summary,range:NSRange(location:0,length:ns.length)) {
            let word=ns.substring(with:match.range)
            if !common.contains(word),!canonical.contains(word.lowercased()) {return nil}
        }
        return MemoryDraft(title:title,summary:summary,quotes:Array(supported.prefix(3)))
    }
    static func fallback(_ phrases:[String],entries:[HistoryEntry])->MemoryDraft? {
        let raw=entries.flatMap{clean($0)}
        let valid=phrases.filter{phrase in phrase.utf8.count>=12 && phrase.utf8.count<=160 && substantive(phrase) && raw.contains(where:{$0.contains(phrase)})}
        guard let first=valid.first else {return nil}
        let pieces=first.components(separatedBy:"•").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}
        let topic=pieces.last.flatMap{substantive($0) ? $0:nil} ?? first
        let repeated=entries.filter{clean($0).contains(where:{$0.contains(first)})}.count>1
        let summary="Content about “\(topic)” appeared\(repeated ? " repeatedly":"") during this period."
        return MemoryDraft(title:topic,summary:summary,quotes:[first])
    }
}
