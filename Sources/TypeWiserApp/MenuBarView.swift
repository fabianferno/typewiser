import SwiftUI
import TypeWiserCore

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Engine", selection: $model.mode) {
                Text("On-device").tag(EngineMode.onDevice)
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
            // Not `SettingsLink`: TypeWiser is an `LSUIElement` agent, so it
            // is never the active app when the menu is clicked and the
            // settings window opens behind whatever the user was using.
            // Activating first, then ordering the window front once SwiftUI
            // has created it, puts it where any other window would go.
            Button("Settings…") { openSettingsWindowInFront() }
            if model.updater.isAvailable {
                Button("Check for Updates…") {
                    NSApp.activate(ignoringOtherApps: true)
                    model.updater.checkForUpdates()
                }
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 240)
    }

    private func openSettingsWindowInFront() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        // The window doesn't exist yet on this pass of the run loop, so it
        // can only be raised on the next one.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow()?.makeKeyAndOrderFront(nil)
        }
    }

    /// SwiftUI names the `Settings` scene's window with this identifier; there
    /// is no public API to reach it.
    private func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }
            ?? NSApp.windows.first { $0.canBecomeKey && $0.isVisible && !($0 is NSPanel) }
    }

    private var statusText: String {
        switch model.mode {
        case .onDevice:
            switch OnDeviceRewriter.modelStatus {
            case .available: return "Apple Intelligence · on device"
            case .downloading: return "Basic cleanup · Apple Intelligence still downloading"
            case .notEnabled: return "Basic cleanup · turn on Apple Intelligence for more"
            case .unsupported: return "Basic cleanup · on device"
            }
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
