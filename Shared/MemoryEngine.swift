import Foundation
import FoundationModels

@Generable
struct GeneratedMemoryTopic:Sendable {
    @Guide(description:"The number of the ONE excerpt this subject comes from. Choose important recurring content, not author names or fragments.")
    var excerpt:Int
    @Guide(description:"Copy a short distinctive subject phrase EXACTLY from that excerpt: the specific product, title, discussion or plan. No generic categories or whole paragraphs.")
    var subject:String
    @Guide(description:"Copy one concrete detail EXACTLY from the same excerpt, such as a feature, price or discussion point. Empty string if there is no clear detail.")
    var detail:String
}

@Generable
struct GeneratedMemory:Sendable {
    @Guide(description:"Up to three distinct concrete subjects, with supporting excerpt numbers. Omit unclear fragments and generic categories.",.maximumCount(3))
    var topics:[GeneratedMemoryTopic]
}

actor MemoryEngine {
    private let folder:URL
    private let submit:@Sendable (String)->Bool
    private var task:Task<Void,Never>?
    private var working=false
    private var pendingForce=false
    private var stopped=true
    private var generation:Task<GeneratedMemory,Error>?
    private var retryAfter:Date = .distantPast
    init(folder:URL,submit:@escaping @Sendable (String)->Bool) { self.folder=folder;self.submit=submit }
    func start() {
        guard task == nil else { return };stopped=false
        task=Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return };await self.tick()
                do { try await Task.sleep(for:.seconds(60)) } catch { break }
            }
        }
    }
    func stop() { stopped=true;pendingForce=false;generation?.cancel();task?.cancel();task=nil }
    func force() async {
        retryAfter = .distantPast
        if working {pendingForce=true;return}
        await tick(force:true)
    }
    private func status(_ state:String,details:[String:Any]=[:]) {
        var row=details;row["state"]=state;row["updated_at"]=Date().timeIntervalSince1970
        if let data=try? JSONSerialization.data(withJSONObject:row) { try? data.write(to:folder.appendingPathComponent("memory-status.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication]) }
    }
    private func tick(force:Bool=false) async {
        guard !stopped, !working, Date()>=retryAfter else { return };working=true
        defer {
            working=false
            if pendingForce,!stopped {pendingForce=false;Task {await self.force()}}
        }
        guard SystemLanguageModel.default.isAvailable else {
            status("model_unavailable",details:["availability":String(describing:SystemLanguageModel.default.availability),"model_available":false,"evidence_preserved":true]);return
        }
        do {
            let now=Date().timeIntervalSince1970
            let entries=try HistoryReader.readNewest(StoragePolicy.historyFiles(folder),limit:800,since:Date(timeIntervalSince1970:now-7*86400)).entries
            let memories=entries.compactMap{$0.memory}
            let cursorURL=folder.appendingPathComponent("memory-cursor.json")
            var cursor=(try? JSONSerialization.jsonObject(with:Data(contentsOf:cursorURL))) as? [String:Double] ?? [:]
            if cursor["format_revision"] != 10 {cursor=[:]}
            let raw=entries.filter{$0.memory == nil && !NaturalMemory.clean($0).isEmpty && $0.date.timeIntervalSince1970>=now-7200}.sorted{$0.date<$1.date}
            var scope="10min";var input:[HistoryEntry]=[];var start=0.0;var end=0.0
            let rollup=memories.filter{$0.format == 10 && $0.scope == "10min" && $0.end>(cursor["rollup_end"] ?? now-21600) && floor($0.start/21600)*21600+21600<=now}.sorted{$0.start<$1.start}.first
            if force {
                start=now-600;end=now
                input=raw.filter{$0.date.timeIntervalSince1970>=start && $0.date.timeIntervalSince1970<=end}
            } else if let first=rollup {
                scope="6h";start=floor(first.start/21600)*21600;end=start+21600
                input=entries.filter{$0.memory?.format == 10 && $0.memory?.scope == "10min" && $0.memory!.start>=start && $0.memory!.end<=end}
            } else {
                let windows=Set(raw.map{floor($0.date.timeIntervalSince1970/600)*600}).sorted(by:>)
                guard let window=windows.first(where:{(cursor["window_"+String(Int($0))] ?? 0)<min($0+600,now) && (force || $0+600<=now)}) else {
                    status("collecting",details:["model_available":true,"next_window_end":floor(now/600)*600+600]);return
                }
                start=window;end=min(start+600,now)
                input=raw.filter{$0.date.timeIntervalSince1970>=start && $0.date.timeIntervalSince1970<end}
            }
            let supplied=NaturalMemory.representative(input)
            guard !supplied.isEmpty else {status("collecting",details:["model_available":true]);return}
            let excerpts=NaturalMemory.excerpts(supplied)
            let evidence=NaturalMemory.excerptPrompt(excerpts)
            status("summarizing",details:["scope":scope,"source_count":supplied.count,"model_available":true])
            if phone_history_native_footprint(0)>30*1024*1024 {
                retryAfter=Date().addingTimeInterval(60);status("deferred",details:["evidence_preserved":true,"model_available":true,"reason":"memory_headroom"]);return
            }
            var natural:MemoryDraft?=nil
            do {
                let session=LanguageModelSession(instructions:MemoryPrompts.generation)
                let request=Task {try await session.respond(to:MemoryPrompts.request(scope:scope,evidence:evidence),generating:GeneratedMemory.self,options:GenerationOptions(sampling:.greedy)).content}
                generation=request
                let watchdog=Task {do {try await Task.sleep(for:.seconds(45));request.cancel()} catch {}}
                defer {watchdog.cancel();generation=nil}
                let value=try await request.value
                natural=NaturalMemory.compose(value.topics.map{MemoryTopic(subject:$0.subject,excerpts:[$0.excerpt],detail:$0.detail)},excerpts:excerpts)
            } catch {
                // Model refusal or invalid output must not erase evidence or
                // attribute a quoted author's actions to the phone owner.
                guard !Task.isCancelled,!stopped else {return}
            }
            guard !Task.isCancelled,!stopped else {return}
            let draft=natural ?? NaturalMemory.excerptFallback(excerpts)
            guard let draft else {
                var next=cursor;next["format_revision"]=10
                if scope == "10min" {next["window_"+String(Int(start))]=end} else {next["rollup_end"]=end}
                try JSONSerialization.data(withJSONObject:next).write(to:cursorURL,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
                status("collecting",details:["model_available":true,"evidence_preserved":true,"no_supported_topics":true]);return
            }
            let record=MemoryRecord(id:"m-"+UUID().uuidString,scope:scope,start:start,end:end,
                title:draft.title,summary:draft.summary,facts:draft.quotes,sources:supplied.map{$0.id},
                apps:Array(Set(supplied.filter{ContextText.usefulLabel($0.label)}.map{MemoryText.bounded($0.label,bytes:80)})).sorted(),partial:true,evidenceChecked:true,generatedAt:Date().timeIntervalSince1970,model:natural == nil ? "deterministic-evidence":"apple-system-language-model",format:10,activityInferred:natural != nil)
            let row=String(decoding:try record.rowData(),as:UTF8.self)
            let acknowledged=await Task.detached(priority:.utility) { self.submit(row) }.value
            guard !stopped, !Task.isCancelled else {return}
            guard acknowledged else { throw DesktopAccess.AccessError.invalidRequest }
            var next=cursor;next["format_revision"]=10
            if scope == "10min" { next["window_"+String(Int(start))]=end }
            else { next["rollup_end"]=end }
            try JSONSerialization.data(withJSONObject:next).write(to:cursorURL,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            status("ready",details:["last_memory_id":record.id,"scope":scope,"source_count":supplied.count,"model_available":true,"last_generated_at":record.generatedAt,"summary_style":natural == nil ? "content_fallback":"model_prose"])
        } catch {
            guard !stopped, !Task.isCancelled else {return}
            retryAfter=Date().addingTimeInterval(300)
            status("deferred",details:["reason":MemoryText.bounded(String(describing:error),bytes:220),"evidence_preserved":true,"retry_after":retryAfter.timeIntervalSince1970])
        }
    }
}
