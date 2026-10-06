import Foundation

// Shared identifiers are generated from the developer's local build config.
// Neutral defaults also keep command-line protocol fixtures independent of signing.
enum BuildConfiguration {
    static let group = Bundle.main.object(forInfoDictionaryKey: "PhoneHistoryAppGroup") as? String ?? "group.com.example.phonehistory"
    static let provider = Bundle.main.object(forInfoDictionaryKey: "PhoneHistoryProvider") as? String ?? "com.example.phonehistory.capture"
    static let controlKind = Bundle.main.object(forInfoDictionaryKey: "PhoneHistoryControlKind") as? String ?? "com.example.phonehistory.capture-toggle"
}
