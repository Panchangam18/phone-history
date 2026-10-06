import Foundation
import WidgetKit

enum CaptureControlState {
    static let kind = BuildConfiguration.controlKind

    static func isEnabled() -> Bool {
        guard let folder = try? HistoryPaths.folder(),
              let data = try? Data(contentsOf: folder.appendingPathComponent("capture-control.json")),
              let state = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any] else { return false }
        return state["enabled"] as? Bool ?? false
    }

    // Written only when configuration or tunnel state changes. No timer or
    // history read is needed to keep the Control Center control up to date.
    static func update(enabled: Bool) {
        guard isEnabled() != enabled else { return }
        guard let folder = try? HistoryPaths.folder(),
              let data = try? JSONSerialization.data(withJSONObject: [
                "enabled": enabled, "updated_at": Date().timeIntervalSince1970
              ]) else { return }
        do {
            try data.write(to: folder.appendingPathComponent("capture-control.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            ControlCenter.shared.reloadControls(ofKind: kind)
        } catch { /* A control refresh must not interrupt capture. */ }
    }
}
