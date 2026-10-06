import AppIntents
import Foundation
import NetworkExtension

// LiveActivityIntent makes the system execute this action in the containing
// app process. It does not create a Live Activity or foreground the app.
struct SetCaptureIntent: SetValueIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Set Phone History Capture"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Enabled") var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        guard let manager = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == HistoryPaths.provider
        }) else { throw CaptureControlError.setupNeeded }

        if value {
            let pairing = try HistoryPaths.folder().appendingPathComponent("remote-pairing.plist")
            guard FileManager.default.fileExists(atPath: pairing.path) else { throw CaptureControlError.setupNeeded }
            manager.isEnabled = true
            let rule = NEOnDemandRuleConnect(); rule.interfaceTypeMatch = .any
            manager.onDemandRules = [rule]; manager.isOnDemandEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            if [.invalid, .disconnected, .disconnecting].contains(manager.connection.status) {
                // Wait for any previous stop before starting again.
                for _ in 0..<20 where manager.connection.status == .disconnecting {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try manager.connection.startVPNTunnel()
            }
            for _ in 0..<40 {
                if manager.connection.status == .connected || manager.connection.status == .reasserting { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            let active = manager.connection.status == .connected || manager.connection.status == .reasserting
            CaptureControlState.update(enabled: active)
            guard active else { throw CaptureControlError.startFailed }
        } else {
            // Disable reconnect before stopping, so a manual pause stays paused.
            manager.isOnDemandEnabled = false
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            manager.connection.stopVPNTunnel()
            for _ in 0..<20 {
                if [.invalid, .disconnected].contains(manager.connection.status) { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            let active = ![NEVPNStatus.invalid, .disconnected].contains(manager.connection.status)
            CaptureControlState.update(enabled: active)
            guard !active else { throw CaptureControlError.stopFailed }
        }
        return .result()
    }
}

enum CaptureControlError: LocalizedError {
    case setupNeeded, startFailed, stopFailed
    var errorDescription: String? {
        switch self {
        case .setupNeeded: return "Open Phone History and finish setup before using this control."
        case .startFailed: return "Capture did not start. Open Phone History to check its status."
        case .stopFailed: return "Capture is still stopping. Open Phone History to check its status."
        }
    }
}
