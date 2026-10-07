import Foundation
import CryptoKit

enum DeveloperTrust {
    enum ImportError: LocalizedError {
        case invalid, alreadyRunning
        var errorDescription: String? {
            switch self {
            case .invalid: return "Choose the developer trust file exported for this iPhone by your own Mac. Its signing keys must match."
            case .alreadyRunning: return "Pause capture before replacing developer trust."
            }
        }
    }
    // Accept only the native schema, never an ordinary USB pairing record.
    // Normalization strips unrelated fields and checks the Ed25519 key pair.
    static func normalized(_ data: Data) throws -> Data {
        guard data.count <= 65536,
              let record = try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],
              let secret = record["private_key"] as? Data, secret.count == 32,
              let publicKey = record["public_key"] as? Data, publicKey.count == 32,
              let identifier = record["identifier"] as? String, !identifier.isEmpty, identifier.utf8.count <= 256,
              identifier.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation:secret),
              key.publicKey.rawRepresentation == publicKey else { throw ImportError.invalid }
        var native: [String:Any] = ["private_key":secret,"public_key":publicKey,"identifier":identifier]
        if let raw = record["alt_irk"] {
            guard let irk = raw as? Data, irk.count == 16 else { throw ImportError.invalid }
            native["alt_irk"] = irk
        }
        return try PropertyListSerialization.data(fromPropertyList:native,format:.binary,options:0)
    }
    static func install(_ source: URL, folder: URL) throws {
        guard let size = try source.resourceValues(forKeys:[.fileSizeKey]).fileSize, size <= 65536 else { throw ImportError.invalid }
        let data = try normalized(Data(contentsOf:source))
        let destination = folder.appendingPathComponent("remote-pairing.plist")
        try data.write(to:destination,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
        var protected = destination
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
    }
}
