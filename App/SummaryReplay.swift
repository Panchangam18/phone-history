#if DEBUG
import Foundation
import FoundationModels

// Developer-only model replay. Reads explicit local fixtures, creates no history
// records, does not move focus or capture frames, and makes no network requests.
enum SummaryReplay {
    static func run() async {
        guard let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else{return}
        var folder=documents.appendingPathComponent("summary-replay",isDirectory:true)
        var privacy=URLResourceValues();privacy.isExcludedFromBackup=true;try? folder.setResourceValues(privacy)
        guard let files=try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) else{return}
        for file in files.filter({$0.lastPathComponent.hasSuffix("-input.json")}).sorted(by:{$0.lastPathComponent<$1.lastPathComponent}) {
            var result:[String:Any]=["model_available":SystemLanguageModel.default.isAvailable,"device":"iPhone","build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? ""]
            let start=Date();result["started_at"]=start.timeIntervalSince1970
            do {
                guard SystemLanguageModel.default.isAvailable else{throw CocoaError(.featureUnsupported)}
                let raw=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]
                let rows=raw?["entries"] as? [[String:Any]] ?? []
                let entries=rows.compactMap{row -> HistoryEntry? in
                    guard let time=row["timestamp"] as? Double,let text=row["text"] as? [String] else{return nil}
                    return HistoryEntry(date:Date(timeIntervalSince1970:time),label:row["app_label"] as? String ?? "",text:text,id:row["id"] as? String ?? "",source:row["source"] as? String ?? "AX",appIdentityVerified:row["host_app_identity_verified"] as? Bool ?? false)
                }
                let excerpts=NaturalMemory.excerpts(entries)
                guard !excerpts.isEmpty else{result["skipped_empty_input"]=true;throw CocoaError(.fileReadUnknown)}
                let request=Task {try await MemoryGeneration.generate(scope:"10min",excerpts:excerpts)}
                let timeout=Task {do {try await Task.sleep(for:.seconds(45));request.cancel()} catch {}}
                defer {timeout.cancel()}
                let value=try await request.value
                let draft=NaturalMemory.grounded(title:value.title,summary:value.summary,lines:value.support.map{(excerpt:$0.excerpt,line:$0.line)},excerpts:excerpts)
                result["title"]=value.title;result["summary"]=value.summary;result["grounding"]=value.grounding
                result["references"]=value.support.map{["excerpt":$0.excerpt,"line":$0.line]}
                result["quotes"]=draft?.quotes ?? [];result["validated"]=draft != nil
                result["supportSources"]=draft?.supportSources ?? []
            } catch {result["error"]=MemoryText.bounded(String(describing:error),bytes:400)}
            result["elapsed_seconds"]=Date().timeIntervalSince(start)
            let output=folder.appendingPathComponent(file.lastPathComponent.replacingOccurrences(of:"-input.json",with:"-result.json"))
            if let data=try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]) {
                try? data.write(to:output,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }
}
#endif
