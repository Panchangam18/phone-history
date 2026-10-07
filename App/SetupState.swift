import Foundation

struct SetupState {
    enum Step: Int, CaseIterable { case capture, desktop }
    static let version = "setup.v2"
    static func step(_ defaults: UserDefaults = .standard) -> Step {
        Step(rawValue:defaults.integer(forKey:version + ".step")) ?? .capture
    }
    static func save(_ step: Step, defaults: UserDefaults = .standard) {
        defaults.set(step.rawValue,forKey:version + ".step")
    }
    static func complete(_ defaults: UserDefaults = .standard) { defaults.set(true,forKey:version + ".complete") }
    static func captureIsReady(vpnConnected:Bool, workerState:String?, updatedAt:Double, now:Double = Date().timeIntervalSince1970) -> Bool {
        let age=now-updatedAt
        return vpnConnected && workerState == "running" && age >= 0 && age < 90
    }
    static func canAdvance(_ step: Step, hasTrust: Bool, captureVerified: Bool) -> Bool {
        hasTrust && captureVerified
    }
    static func shouldPresent(hasExistingSetup: Bool, defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey:version + ".complete") && (!hasExistingSetup || defaults.object(forKey:version + ".step") != nil)
    }
}
