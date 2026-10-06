import Foundation
import CryptoKit

struct StoragePolicy: Codable, Equatable {
    enum Mode:String,Codable { case none, window, send }
    var mode:Mode = .window
    var maxBytes:Int = 512 * 1024
    private enum CodingKeys:String,CodingKey { case mode,maxBytes,receiverID }
    init() {}
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        mode=try c.decode(Mode.self,forKey:.mode)
        maxBytes=try c.decodeIfPresent(Int.self,forKey:.maxBytes) ?? 512 * 1024
        receiverID=try c.decodeIfPresent(String.self,forKey:.receiverID)
        guard (64 * 1024...5 * 1024 * 1024).contains(maxBytes) else { throw DesktopAccess.AccessError.invalidRequest }
    }
    var receiverID:String? = nil
    static func load(_ folder:URL) throws -> Self {
        let url=folder.appendingPathComponent("storage-settings.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
    }
    func save(_ folder:URL) throws {
        guard (64 * 1024...5 * 1024 * 1024).contains(maxBytes) else { throw DesktopAccess.AccessError.invalidRequest }
        try JSONEncoder().encode(self).write(to:folder.appendingPathComponent("storage-settings.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
    static func activeReceiver(_ folder:URL, now:Double = Date().timeIntervalSince1970) -> DesktopPair? {
        guard let serverData=try? Data(contentsOf:folder.appendingPathComponent("desktop-server.json")),
              let server=(try? JSONSerialization.jsonObject(with:serverData)) as? [String:Any], server["state"] as? String == "ready",
              let data=try? Data(contentsOf:folder.appendingPathComponent("active-receiver.json")),
              let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let seen=value["seen_at"] as? Double, now >= seen, now-seen < 90,
              let id=value["pair_id"] as? String,
              let state=try? DesktopAccess.load(folder) else { return nil }
        return state.pairs.first { $0.id == id }
    }
    static func historyFiles(_ folder:URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at:folder.appendingPathComponent("Records"),includingPropertiesForKeys:nil)) ?? []).filter { day($0.lastPathComponent) != nil }
    }
    static func day(_ name:String) -> Double? {
        guard name.hasPrefix("history-"),name.hasSuffix(".jsonl") else { return nil }
        guard let day=Double(name.dropFirst(8).dropLast(6).split(separator:"-").first ?? ""),day.isFinite,day>=0,day.rounded(.down)==day else { return nil }
        return day
    }
    static func hash(_ url:URL) throws -> String {
        let handle=try FileHandle(forReadingFrom:url);defer { try? handle.close() };var hash=SHA256()
        while let data=try handle.read(upToCount:65536), !data.isEmpty { hash.update(data:data) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
