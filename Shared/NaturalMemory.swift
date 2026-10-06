import Foundation

struct MemoryDraft:Sendable {
    let title:String
    let summary:String
    let quotes:[String]
}

struct MemoryTopic:Sendable {
    let subject:String
    let excerpts:[Int]
    var detail:String = ""
}
struct MemoryExcerpt:Sendable {
    let number:Int
    let text:String
    let entry:HistoryEntry
}

enum NaturalMemory {
    private static let connectiveWords=Set(["a","an","the","and","or","but","for","of","to","in","on","at","by","from","with","is","are","was","were","be","been","it","its","this","that","these","those","i","you","he","she","they","we","my","your","his","her","their","our","as","so","if","then","than","not","yes","yeah"])
    static func substantive(_ text:String)->Bool {
        // Digits inside a single OCR username must not turn it into two words.
        guard text.split(whereSeparator:{$0.isWhitespace}).filter({$0.contains(where:{$0.isLetter})}).count>=2 else {return false}
        let words=text.lowercased().split(whereSeparator:{!$0.isLetter}).map(String.init)
        return words.filter{!connectiveWords.contains($0) && $0.count>=3}.count>=2
    }
    private static let genericWords=Set(["you","your","browsed","browse","browsing","reviewed","review","reviewing","checked","check","checking","explored","explore","exploring","read","reading","viewed","viewing","looked","looking","scrolling","scrolled","visited","opened","returned","switched","focused","featuring","centered","discussed","related","including","included","about","through","latest","recent","several","few","various","different","mix","topics","topic","subject","subjects","content","page","pages","post","posts","feed","feeds","platform","platforms","social","media","news","updates","update","technology","tech","hardware","software","computer","computers","development","developments","industry","community","communities","networking","opportunities","advancements","discussion","discussions","comments","replies","people","information","personal","introducing","general","main","specific","period","screen","visible"])
    private static func tokens(_ text:String)->Set<String> {
        Set(text.lowercased().split(whereSeparator:{!$0.isLetter}).map(String.init).filter{$0.count>=3 && !connectiveWords.contains($0) && !genericWords.contains($0)})
    }
    static func metadataOnly(_ line:String)->Bool {
        // Generic handle/timestamp rows are context, not evidence of a subject.
        let s=line.trimmingCharacters(in:.whitespacesAndNewlines)
        if s.hasPrefix("@"),s.split(whereSeparator:{$0.isWhitespace}).count<=3 {return true}
        if s.contains("@"),s.range(of:#"(?:\d+\s*[mhdw]|follows(?: you)?)\s*$"#,options:[.regularExpression,.caseInsensitive]) != nil,s.split(whereSeparator:{$0.isWhitespace}).count<=9 {return true}
        if s.contains("•"),s.hasSuffix("•"),s.split(whereSeparator:{$0.isWhitespace}).count<=6 {return true}
        return false
    }
    private static func contentLines(_ entry:HistoryEntry,headers:Bool)->[String] {
        if let memory=entry.memory {return [memory.title,memory.summary]+memory.facts}
        var result:[String]=[];var ad=false;var paragraph:[String]=[]
        func flush() {
            let text=paragraph.joined(separator:" ")
            if text.utf8.count>=12,substantive(text) {result.append(text)}
            paragraph=[]
        }
        for raw in entry.text {
            let line=raw.trimmingCharacters(in:.whitespacesAndNewlines)
            if ["ad","ad.","sponsored","promoted"].contains(line.lowercased()) {
                flush()
                if let last=result.last,last.hasPrefix("Context label (not a supporting quote):") {result.removeLast()}
                ad=true;continue
            }
            if ad {if metadataOnly(line) {ad=false} else {continue}}
            if metadataOnly(line) {
                flush()
                if headers {result.append("Context label (not a supporting quote): "+line)}
                continue
            }
            guard ContextText.meaningful(line) else {flush();continue}
            // OCR wraps paragraphs at the screen edge. Keep contiguous text
            // together, including one-word continuations of a heading.
            if paragraph.joined(separator:" ").utf8.count+line.utf8.count>480 {flush()}
            paragraph.append(line)
        }
        flush()
        return result
    }
    static func clean(_ entry:HistoryEntry)->[String] {contentLines(entry,headers:false)}
    static func representative(_ entries:[HistoryEntry],limit:Int=24)->[HistoryEntry] {
        let values=entries.filter{!clean($0).isEmpty}.sorted{$0.date<$1.date}
        guard values.count>limit,limit>1 else {return values}
        return (0..<limit).map{values[$0*(values.count-1)/(limit-1)]}
    }
    static func prompt(_ entries:[HistoryEntry])->String {
        struct Block {var first:Date;var last:Date;let label:String;var lines:[String];var count:Int}
        var blocks:[Block]=[]
        for entry in entries.sorted(by:{$0.date<$1.date}) {
            let content=contentLines(entry,headers:true)
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
    static func excerpts(_ entries:[HistoryEntry])->[MemoryExcerpt] {
        let values=representative(entries).sorted{$0.date<$1.date}
        let ranked=values.map{entry in clean(entry).filter{!tokens($0).isEmpty}.sorted{a,b in
            func score(_ s:String)->Int {
                let correction=s.range(of:#"\b(?:typo|correction|corrected)\b"#,options:[.regularExpression,.caseInsensitive]) != nil
                let heading=s.range(of:#"^(?:introducing|announcing|launching)\b"#,options:[.regularExpression,.caseInsensitive]) != nil
                return min(s.utf8.count,140)+tokens(s).count*12+(heading ? 160:0)+(correction ? 1000:0)
            }
            return score(a)>score(b)
        }}
        var chosen:[(String,HistoryEntry)]=[];var seen=Set<String>();var used=0
        // Cover observations before taking more lines from the same screen.
        for depth in 0..<2 {
            for (index,entry) in values.enumerated() where ranked[index].indices.contains(depth) {
                let text=MemoryText.bounded(ranked[index][depth],bytes:480)
                guard seen.insert(entry.label+"|"+text).inserted else {continue}
                let cost=text.utf8.count+80
                guard used+cost<=5800,chosen.count<40 else {continue}
                used+=cost;chosen.append((text,entry))
            }
        }
        return chosen.enumerated().map{MemoryExcerpt(number:$0.offset+1,text:$0.element.0,entry:$0.element.1)}
    }
    static func excerptPrompt(_ excerpts:[MemoryExcerpt])->String {
        excerpts.map{item in
            let label=ContextText.usefulLabel(item.entry.label) ? item.entry.label:"unknown"
            return "[\(item.number)] Process: \(MemoryText.bounded(label,bytes:80)). Content: \(item.text)"
        }.joined(separator:"\n")
    }
    static func compose(_ topics:[MemoryTopic],excerpts:[MemoryExcerpt])->MemoryDraft? {
        var parts:[String]=[];var subjects:[String]=[];var quotes:[String]=[];var seen=Set<String>()
        let correction=excerpts.contains{$0.text.range(of:#"\b(?:typo|correction|corrected)\b"#,options:[.regularExpression,.caseInsensitive]) != nil}
        for topic in topics.prefix(3) {
            let subject=topic.subject.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !subject.isEmpty,subject.utf8.count<=180,
                  subject.range(of:#"\b(?:I|you|your|my|me|our)\b"#,options:[.regularExpression,.caseInsensitive]) == nil,
                  !subject.contains("\n"),seen.insert(subject.lowercased()).inserted else {continue}
            if subject.split(whereSeparator:{$0.isWhitespace}).count==1,
               subject.first?.isLowercase == true {continue}
            let references=topic.excerpts.compactMap{number in excerpts.first{$0.number==number}}
            guard !references.isEmpty,Set(topic.excerpts).count==references.count else {continue}
            func normalized(_ text:String)->String {text.lowercased().split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")}
            // Each subject must be copied from a single cited excerpt. Do not
            // attach unrelated citations or manufacture a claim across screens.
            let sources=references.filter{normalized($0.text).contains(normalized(subject))}
            guard let source=sources.first,!tokens(subject).isEmpty,subject.utf8.count>=4 else {continue}
            let label=source.entry.label
            let detail=topic.detail.trimmingCharacters(in:.whitespacesAndNewlines)
            if correction,(subject+detail).contains(where:{$0.isNumber}),
               source.text.range(of:#"\b(?:typo|correction|corrected)\b"#,options:[.regularExpression,.caseInsensitive]) == nil {continue}
            let supportedDetail = !detail.isEmpty && detail.utf8.count<=160 && detail.utf8.count>=8 && detail.contains(where:{$0.isLetter}) && normalized(source.text).contains(normalized(detail)) && !normalized(subject).contains(normalized(detail))
            let clause=subject+(ContextText.usefulLabel(label) ? " in \(label)":"")+(supportedDetail ? ", including “"+detail+"”":"")
            // Fixed wording cannot turn an author's story into owner actions.
            subjects.append(subject);parts.append((parts.isEmpty ? "You reviewed ":"You also reviewed ")+clause+".")
            if !quotes.contains(subject),quotes.count<3 {quotes.append(subject)}
            if supportedDetail,!quotes.contains(detail),quotes.count<3 {quotes.append(detail)}
        }
        guard let first=subjects.first else {return nil}
        let summary=parts.joined(separator:" ")
        guard summary.utf8.count<=1000 else {return nil}
        return MemoryDraft(title:MemoryText.bounded(first,bytes:160),summary:summary,quotes:quotes)
    }
    static func excerptFallback(_ excerpts:[MemoryExcerpt])->MemoryDraft? {
        guard !excerpts.isEmpty else {return nil}
        let selected=Array(excerpts.prefix(2))
        let quotes=selected.map{MemoryText.bounded($0.text,bytes:220)}
        let labels=Set(selected.map{$0.entry.label})
        let app=labels.count==1 && ContextText.usefulLabel(selected[0].entry.label) ? " in "+selected[0].entry.label:""
        // Exact excerpts stay explicitly quoted if the model cannot select a
        // subject. This preserves content without inventing an interpretation.
        return MemoryDraft(title:MemoryText.bounded(quotes[0],bytes:160),
            summary:"You reviewed content\(app), including "+quotes.map{"“"+$0+"”"}.joined(separator:" and ")+".",quotes:quotes)
    }
    static func checked(_ draft:MemoryDraft,entries:[HistoryEntry])->MemoryDraft? {
        let title=draft.title.trimmingCharacters(in:.whitespacesAndNewlines)
        let summary=draft.summary.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty,title.utf8.count<=160,!summary.isEmpty,summary.utf8.count<=1000 else {return nil}
        let text=entries.flatMap{clean($0)}
        let quotes=Array(Set(draft.quotes.map{$0.trimmingCharacters(in:.whitespacesAndNewlines)})).sorted().filter {
            $0.utf8.count>=12 && $0.utf8.count<=480 && substantive($0)
        }
        // Bind each supporting quote to actual content, not a provenance header.
        let supported=quotes.filter{quote in text.contains(where:{$0.contains(quote)})}
        guard !supported.isEmpty else {return nil}
        // Prose must retain distinctive content from its supporting quotes.
        // Generic activity/category words alone cannot pass this gate.
        let anchors=Set(supported.flatMap{tokens($0)})
        let overlap=anchors.intersection(tokens(summary))
        guard !anchors.isEmpty,overlap.count>=min(2,anchors.count) else {return nil}
        let lower=summary.lowercased()
        guard !lower.contains("observed screen text"),!lower.contains("screen text included"),!lower.contains("interact") else {return nil}
        let action=#"\b(?:messaged|sent|received|watched|typed|clicked|tapped|purchased|bought|paid|booked|scheduled|submitted|deleted|signed|approved|accepted|won|lost|played|listened|replied|liked|posted|shared|completed|finished|agreed|engaged|participated|commented|responded|networked|interested|wanted|decided|felt|believed|enjoyed)\b"#
        guard lower.range(of:action,options:.regularExpression)==nil else {return nil}
        let body=(text+entries.flatMap{ContextText.content($0.text)}+entries.filter{ContextText.usefulLabel($0.label)}.map{$0.label}).joined(separator:" ").lowercased()
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
        let valid=phrases.filter{phrase in phrase.utf8.count>=12 && phrase.utf8.count<=160 && substantive(phrase) && !tokens(phrase).isEmpty && raw.contains(where:{$0.contains(phrase)})}
        guard let first=valid.first else {return nil}
        let pieces=first.components(separatedBy:"•").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}
        let topic=pieces.last.flatMap{substantive($0) ? $0:nil} ?? first
        let repeated=entries.filter{clean($0).contains(where:{$0.contains(first)})}.count>1
        let summary="Content about “\(topic)” appeared\(repeated ? " repeatedly":"") during this period."
        return MemoryDraft(title:topic,summary:summary,quotes:[first])
    }
}
