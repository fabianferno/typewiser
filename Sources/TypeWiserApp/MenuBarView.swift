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

            // Read from `model.hasAccessibility` (kept live by `AppModel`),
            // never `HotkeyMonitor.hasAccessibilityPermission()` inline here —
            // a direct call in the view body wouldn't be tracked by
            // Observation, so the menu would never re-render when permission
            // is granted.
            if !model.hasAccessibility {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Dictation disabled — Accessibility required", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("TypeWiser cannot detect the 🌐 key or paste text into other apps until this is granted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Grant Accessibility Permission…") {
                        HotkeyMonitor.requestAccessibilityPermission()
                    }
                    Button("Open System Settings…") {
                        HotkeyMonitor.openAccessibilitySettings()
                    }
                    Text("If macOS already denied the prompt, it won't ask again — add TypeWiser under Privacy & Security → Accessibility and enable it there.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Divider()
            }
            SettingsLink { Text("Settings…") }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 240)
    }

    private var statusText: String {
        switch model.mode {
        case .cloud:
            guard model.hasCloudCredentials() else {
                return "Cloud · no credentials — add them in Settings"
            }
            return "Bedrock Nova Lite · ap-south-1"
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
