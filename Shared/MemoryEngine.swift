import Foundation
import FoundationModels

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
            if cursor["format_revision"] != 18 {cursor=[:]}
            let raw=entries.filter{$0.memory == nil && !NaturalMemory.clean($0).isEmpty && $0.date.timeIntervalSince1970>=now-7200}.sorted{$0.date<$1.date}
            var scope="10min";var input:[HistoryEntry]=[];var start=0.0;var end=0.0
            let rollup=memories.filter{$0.format == 18 && $0.scope == "10min" && $0.end>(cursor["rollup_end"] ?? now-21600) && floor($0.start/21600)*21600+21600<=now}.sorted{$0.start<$1.start}.first
            if force {
                start=now-600;end=now
                input=raw.filter{$0.date.timeIntervalSince1970>=start && $0.date.timeIntervalSince1970<=end}
            } else if let first=rollup {
                scope="6h";start=floor(first.start/21600)*21600;end=start+21600
                let children=entries.compactMap{$0.memory}.filter{$0.format == 18 && $0.scope == "10min" && $0.start>=start && $0.end<=end}
                // Re-ground rollups in captured observations, not earlier model prose.
                // A mistaken ten-minute interpretation must not become source truth.
                let ids=Set(children.flatMap{$0.sources})
                input=try HistoryReader.readIDs(StoragePolicy.historyFiles(folder),ids:ids).entries.filter{$0.memory == nil}
                if input.isEmpty {
                    cursor["rollup_end"]=end
                    try JSONSerialization.data(withJSONObject:cursor).write(to:cursorURL,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
                    status("collecting",details:["model_available":true,"reason":"rollup_evidence_expired"]);return
                }
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
            status("summarizing",details:["scope":scope,"source_count":supplied.count,"model_available":true])
            if phone_history_native_footprint(0)>30*1024*1024 {
                retryAfter=Date().addingTimeInterval(60);status("deferred",details:["evidence_preserved":true,"model_available":true,"reason":"memory_headroom"]);return
            }
            var natural:MemoryDraft?=nil
            var failure="invalid_output_or_quotes"
            do {
                let request=Task {try await MemoryGeneration.generate(scope:scope,excerpts:excerpts)}
                generation=request
                let watchdog=Task {do {try await Task.sleep(for:.seconds(45));request.cancel()} catch {}}
                defer {watchdog.cancel();generation=nil}
                let value=try await request.value
                if value.title.isEmpty,value.summary.isEmpty,value.support.isEmpty {
                    var next=cursor;next["format_revision"]=18
                    next["abstained_"+scope+"_"+String(Int(start))]=end
                    if scope == "10min" {next["window_"+String(Int(start))]=end} else {next["rollup_end"]=end}
                    try JSONSerialization.data(withJSONObject:next).write(to:cursorURL,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
                    status("collecting",details:["model_available":true,"evidence_preserved":true])
                    return
                }
                if value.title.utf8.count>160 {failure="title_size"}
                else if value.summary.utf8.count>1000 {failure="summary_size"}
                else if value.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || value.summary.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {failure="empty_prose"}
                else {failure="invalid_evidence_references"}
                natural=NaturalMemory.grounded(title:value.title,summary:value.summary,lines:value.support.map{(excerpt:$0.excerpt,line:$0.line)},excerpts:excerpts)
            } catch {
                // Model refusal or invalid output must not erase evidence or
                // attribute a quoted author's actions to the phone owner.
                guard !Task.isCancelled,!stopped else {return}
                if let error=error as? LanguageModelSession.GenerationError {
                    switch error {
                    case .exceededContextWindowSize: failure="context_limit"
                    case .assetsUnavailable: failure="model_assets_unavailable"
                    case .guardrailViolation: failure="guardrail"
                    case .unsupportedGuide: failure="schema_unsupported"
                    case .unsupportedLanguageOrLocale: failure="locale_unsupported"
                    case .decodingFailure: failure="output_decoding"
                    case .rateLimited: failure="model_rate_limited"
                    case .concurrentRequests: failure="concurrent_generation"
                    case .refusal: failure="model_refusal"
                    @unknown default: failure="model_error"
                    }
                } else { failure=error is CancellationError ? "generation_timeout":"generation_error" }
            }
            guard !Task.isCancelled,!stopped else {return}
            guard let draft=natural else {
                retryAfter=Date().addingTimeInterval(300)
                status("deferred",details:["model_available":true,"evidence_preserved":true,"generation_failure":failure])
                return
            }
            let record=MemoryRecord(id:"m-"+UUID().uuidString,scope:scope,start:start,end:end,
                title:draft.title,summary:draft.summary,facts:draft.quotes,sources:supplied.map{$0.id},
                apps:Array(Set(supplied.filter{$0.appIdentityVerified && ContextText.usefulLabel($0.label)}.map{MemoryText.bounded($0.label,bytes:80)})).sorted(),partial:true,evidenceChecked:true,generatedAt:Date().timeIntervalSince1970,model:"apple-system-language-model",format:18,activityInferred:true,supportSources:draft.supportSources)
            let row=String(decoding:try record.rowData(),as:UTF8.self)
            let acknowledged=await Task.detached(priority:.utility) { self.submit(row) }.value
            guard !stopped, !Task.isCancelled else {return}
            guard acknowledged else { throw DesktopAccess.AccessError.invalidRequest }
            var next=cursor;next["format_revision"]=18
            if scope == "10min" { next["window_"+String(Int(start))]=end }
            else { next["rollup_end"]=end }
            try JSONSerialization.data(withJSONObject:next).write(to:cursorURL,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            status("ready",details:["last_memory_id":record.id,"scope":scope,"source_count":supplied.count,"model_available":true,"last_generated_at":record.generatedAt,"summary_style":"model_prose"])
        } catch {
            guard !stopped, !Task.isCancelled else {return}
            retryAfter=Date().addingTimeInterval(300)
            status("deferred",details:["reason":MemoryText.bounded(String(describing:error),bytes:220),"evidence_preserved":true,"retry_after":retryAfter.timeIntervalSince1970])
        }
    }
}
