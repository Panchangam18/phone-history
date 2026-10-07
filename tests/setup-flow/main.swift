import Foundation
import CryptoKit

func expect(_ value:Bool,_ message:String) {precondition(value,message)}
let suite="PhoneHistory.SetupTests.\(UUID().uuidString)"
let defaults=UserDefaults(suiteName:suite)!
defer {defaults.removePersistentDomain(forName:suite)}
expect(SetupState.shouldPresent(hasExistingSetup:false,defaults:defaults),"new phones enter setup")
expect(!SetupState.shouldPresent(hasExistingSetup:true,defaults:defaults),"existing trusted users are not forced through migration")
SetupState.save(.capture,defaults:defaults)
expect(SetupState.step(defaults) == .capture,"interrupted setup resumes")
expect(SetupState.shouldPresent(hasExistingSetup:true,defaults:defaults),"imported trust alone does not finish onboarding")
expect(!SetupState.canAdvance(.capture,hasTrust:false,captureVerified:false),"phone setup cannot skip trust")
expect(!SetupState.canAdvance(.capture,hasTrust:true,captureVerified:false),"VPN approval alone cannot complete capture setup")
expect(SetupState.canAdvance(.desktop,hasTrust:true,captureVerified:true),"desktop approval is optional")
expect(!SetupState.canAdvance(.desktop,hasTrust:true,captureVerified:false),"paused capture is not verified setup")
expect(SetupState.captureIsReady(vpnConnected:true,workerState:"running",updatedAt:980,now:1000),"fresh running worker")
for (connected,state,time) in [(false,"running",980.0),(true,"reconnecting",980.0),(true,"running",900.0),(true,"running",1001.0)] {
    expect(!SetupState.captureIsReady(vpnConnected:connected,workerState:state,updatedAt:time,now:1000),"reject disconnected, unhealthy, stale and future status")
}
SetupState.complete(defaults)
expect(!SetupState.shouldPresent(hasExistingSetup:true,defaults:defaults),"completed users return home")
let key=Curve25519.Signing.PrivateKey()
let record:[String:Any]=["private_key":key.rawRepresentation,"public_key":key.publicKey.rawRepresentation,"identifier":"fixture","unrelated":"discard me"]
func encoded(_ value:[String:Any]) throws -> Data {try PropertyListSerialization.data(fromPropertyList:value,format:.binary,options:0)}
let output=try DeveloperTrust.normalized(encoded(record))
let normalized=try PropertyListSerialization.propertyList(from:output,format:nil) as! [String:Any]
expect(normalized["unrelated"] == nil,"only the required schema is imported")
for change in [["public_key":Data(repeating:0,count:32)],["identifier":""],["identifier":"invalid\nidentifier"],["alt_irk":Data(count:1)],["private_key":Data(count:31)]] as [[String:Any]] {
    var invalid=record;invalid.merge(change) {_,new in new}
    do {_ = try DeveloperTrust.normalized(encoded(invalid));fatalError("invalid record accepted")} catch {}
}
do {_ = try DeveloperTrust.normalized(Data(count:65537));fatalError("oversized input accepted")} catch {}
do {_ = try DeveloperTrust.normalized(encoded(["HostID":"ordinary USB trust"]));fatalError("USB record accepted")} catch {}
let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:folder)}
let source=folder.appendingPathComponent("input.plist")
try encoded(record).write(to:source)
try DeveloperTrust.install(source,folder:folder)
let destination=folder.appendingPathComponent("remote-pairing.plist")
let saved=try Data(contentsOf:destination)
expect(FileManager.default.fileExists(atPath:source.path),"picker source is never silently removed")
let permissions=try FileManager.default.attributesOfItem(atPath:destination.path)[.posixPermissions] as! NSNumber
expect(permissions.intValue == 0o600,"secret import is owner-only")
try encoded(["HostID":"invalid"]).write(to:source)
do {try DeveloperTrust.install(source,folder:folder);fatalError("invalid import accepted")} catch {}
expect(try Data(contentsOf:destination) == saved,"invalid import preserves working trust")
print("Onboarding gates, resume, freshness and protected trust imports passed.")
