import Foundation

enum ContextText {
    private static let clock = try! NSRegularExpression(pattern:#"^\d{1,2}:\d{2}(?:\s*[ap]\.?m\.?)?$"#,options:.caseInsensitive)
    private static let age = try! NSRegularExpression(pattern:#"^\d+\s+(?:second|minute|hour|day|week|month|year)s?\s+ago$"#,options:.caseInsensitive)
    private static let date = try! NSRegularExpression(pattern:#"^(?:(?:today|yesterday|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|january|february|march|april|may|june|july|august|september|october|november|december)|\d{1,4}|[\s,./:-])+$"#,options:.caseInsensitive)
    private static let controls=Set(["app context","phone history","use the app","home","search","follow","following","sign in","log in","back","next","done","cancel","share","like","comment","repost","more","menu","notifications"])
    static func meaningful(_ line:String)->Bool {
        let s=line.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !s.isEmpty,s.contains(where:{$0.isLetter}),!controls.contains(s.lowercased()),s.range(of:#"^\d*\s*Phone History$"#,options:[.regularExpression,.caseInsensitive]) == nil else {return false}
        let range=NSRange(s.startIndex...,in:s)
        if clock.firstMatch(in:s,range:range) != nil || age.firstMatch(in:s,range:range) != nil || date.firstMatch(in:s,range:range) != nil {return false}
        // Ignore tiny OCR fragments; preserve substantive short headings and names.
        return s.utf8.count>=8 && s.filter{$0.isLetter}.count>=4
    }
    static func content(_ lines:[String])->[String] {lines.filter(meaningful)}
    static func usefulLabel(_ label:String)->Bool {
        let s=label.trimmingCharacters(in:.whitespacesAndNewlines)
        return !s.isEmpty && s.lowercased() != "app context" && !s.contains("WidgetRenderer") && !s.contains("WebContent")
    }
    static func title(_ entry:HistoryEntry)->String {
        if let memory=entry.memory {return memory.title}
        let lines=content(entry.text)
        let ranked=lines.sorted {
            let a=($0.split(whereSeparator:{$0.isWhitespace}).count>=3 ? 1000:0)+min($0.utf8.count,140)
            let b=($1.split(whereSeparator:{$0.isWhitespace}).count>=3 ? 1000:0)+min($1.utf8.count,140)
            return a>b
        }
        return ranked.first.map{MemoryText.bounded($0,bytes:160)} ?? (usefulLabel(entry.label) ? entry.label:"Screen content")
    }
}
