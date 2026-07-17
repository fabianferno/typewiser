import AppKit
import SwiftUI
import TypeWiserCore

/// Verifies setup rather than merely instructing. If the 🌐 key is still bound to
/// dictation or the emoji picker, every hold pops a system UI over the user's work.
struct OnboardingView: View {
    let model: AppModel
    @State private var refresh = 0

    private var fnUsage: Int? {
        UserDefaults.standard
            .persistentDomain(forName: "com.apple.HIToolbox")?["AppleFnUsageType"] as? Int
    }

    private var fnIsFree: Bool { fnUsage == 0 }

    var body: some View {
        Form {
            // Reads `model.hasAccessibility` (kept live by `AppModel`), the
            // same source of truth `MenuBarView` uses, rather than calling
            // `HotkeyMonitor.hasAccessibilityPermission()` inline here — this
            // row updates the instant permission is granted, no "Re-check"
            // needed for this one.
            check("Accessibility permission",
                  ok: model.hasAccessibility,
                  detail: model.hasAccessibility
                    ? "Required to detect the 🌐 key and paste into other apps."
                    : "Dictation is disabled without this — TypeWiser can't detect the 🌐 key or paste. If macOS already denied the prompt it won't ask again; use Fix… to open System Settings and enable it manually.") {
                // Harmless no-op if macOS already denied the prompt once;
                // the settings deep link is the guaranteed fallback for
                // that case (see `HotkeyMonitor.openAccessibilitySettings`).
                HotkeyMonitor.requestAccessibilityPermission()
                HotkeyMonitor.openAccessibilitySettings()
            }

            check("🌐 key is free",
                  ok: fnIsFree,
                  detail: fnIsFree
                    ? "Set to Do Nothing."
                    : "Set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, or the emoji picker opens every time you dictate.") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
                )
            }

            Button("Re-check") { refresh += 1 }
        }
        .formStyle(.grouped)
        .id(refresh)
    }

    @ViewBuilder
    private func check(_ title: String, ok: Bool, detail: String, action: @escaping () -> Void) -> some View {
        Section {
            HStack(alignment: .top) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !ok { Button("Fix…", action: action) }
            }
        }
    }
}
