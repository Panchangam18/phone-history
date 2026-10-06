import Foundation

enum HistoryPaths {
    static let group = BuildConfiguration.group
    static let provider = BuildConfiguration.provider
    static func folder() throws -> URL {
        #if targetEnvironment(simulator)
        if CommandLine.arguments.contains("--ui-preview") {
            let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("UIFixtures/History",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            return folder
        }
        #endif
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw NSError(domain: "PhoneHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: "The shared history container is unavailable."])
        }
        let folder = base.appendingPathComponent("History", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
        return folder
    }
}
