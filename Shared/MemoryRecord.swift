import Foundation

struct MemoryRecord: Codable, Sendable {
    let id:String
    let scope:String
    let start:Double
    let end:Double
    let title:String
    let summary:String
    let facts:[String]
    let sources:[String]
    let apps:[String]
    let partial:Bool
    let evidenceChecked:Bool
    let generatedAt:Double
    let model:String
    var format:Int? = nil
    var activityInferred:Bool? = nil
    // Parallel to facts: the observation containing each verbatim supporting quote.
    var supportSources:[String]? = nil
    static func decode(_ row:[String:Any]) -> Self? {
        guard row["kind"] as? String == "memory",let data=try? JSONSerialization.data(withJSONObject:row),
            let value=try? JSONDecoder().decode(Self.self,from:data),value.valid else { return nil }
        return value
    }
    var valid:Bool {
        evidenceChecked && ["10min","6h"].contains(scope) && id.hasPrefix("m-") && id.utf8.count<=64 && start.isFinite && end.isFinite && end>=start &&
        !title.isEmpty && title.utf8.count<=160 && !summary.isEmpty && summary.utf8.count<=1000 && facts.count<=4 &&
        facts.allSatisfy{$0.utf8.count<=240} && !sources.isEmpty && sources.count<=40 && sources.allSatisfy{!$0.isEmpty && $0.utf8.count<=80} &&
        apps.count<=24 && apps.allSatisfy{$0.utf8.count<=80} &&
        (supportSources == nil || (supportSources!.count == facts.count && supportSources!.allSatisfy{sources.contains($0)})) &&
        generatedAt.isFinite && ["apple-system-language-model","deterministic-evidence"].contains(model)
    }
    func rowData() throws -> Data {
        guard valid else { throw DesktopAccess.AccessError.invalidRequest }
        var row=try JSONSerialization.jsonObject(with:JSONEncoder().encode(self)) as! [String:Any]
        row["kind"]="memory";row["v"]=1
        return try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])
    }
}

enum MemoryText {
    static func bounded(_ text:String,bytes:Int) -> String {
        var output="";var count=0
        for c in text { let size=String(c).utf8.count;guard count+size<=bytes else { break };output.append(c);count+=size }
        return output
    }
}
