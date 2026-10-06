import AppIntents
import SwiftUI
import WidgetKit

@main
struct HistoryControls: WidgetBundle {
    var body: some Widget { CaptureToggle() }
}

struct CaptureToggle: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: CaptureControlState.kind, provider: Provider()) { enabled in
            ControlWidgetToggle("Phone History", isOn: enabled, action: SetCaptureIntent()) { isOn in
                Label { Text(isOn ? "On" : "Off") } icon: { Image("HistoryControlMark", bundle: .main)
                    .symbolRenderingMode(.monochrome)
                    .symbolVariant(.none) }
            }.tint(.blue)
        }
        .displayName("Phone History")
        .description("Start or pause history capture on this iPhone.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }
        func currentValue() async throws -> Bool { CaptureControlState.isEnabled() }
    }
}
