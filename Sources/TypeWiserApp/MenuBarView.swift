import SwiftUI
import TypeWiserCore

struct MenuBarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Engine", selection: $model.mode) {
                Text("Local").tag(EngineMode.local)
                Text("Cloud").tag(EngineMode.cloud)
            }
            .pickerStyle(.segmented)

            Text(statusText).font(.caption).foregroundStyle(.secondary)

            Divider()

            if !HotkeyMonitor.hasAccessibilityPermission() {
                Button("Grant Accessibility Permission…") {
                    HotkeyMonitor.requestAccessibilityPermission()
                }
            }
            SettingsLink { Text("Settings…") }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 240)
    }

    private var statusText: String {
        switch model.mode {
        case .cloud: return "Bedrock Nova Lite · ap-south-1"
        case .local:
            switch model.engineState {
            case .stopped: return "Local engine stopped"
            case .starting: return "Loading model… (up to 30s)"
            case .ready: return "Local engine ready · port 8231"
            case .failed(let why): return "Failed: \(why)"
            }
        }
    }
}
