import AppKit
import AVFoundation
import Speech
import SwiftUI
import TypeWiserCore

/// What a fresh Mac needs before dictation works. Shared by the Setup tab and
/// the welcome window so they can never disagree about "done".
@MainActor
enum SetupChecks {
    static var microphoneAllowed: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var speechAllowed: Bool { AppleSpeechTranscriber.isAuthorized }

    /// If the 🌐 key is still bound to dictation or the emoji picker, every
    /// hold pops a system UI over the user's work.
    static var fnIsFree: Bool {
        UserDefaults.standard
            .persistentDomain(forName: "com.apple.HIToolbox")?["AppleFnUsageType"] as? Int == 0
    }

    /// Everything dictation can't work without. Apple Intelligence is not on
    /// this list: without it cleanup degrades to the built-in rules, but
    /// dictation still works.
    static func requiredAreMet(_ model: AppModel) -> Bool {
        model.hasAccessibility && microphoneAllowed && fnIsFree
            && (model.settings.sttSource != .apple || speechAllowed)
    }
}

/// Verifies setup rather than merely instructing.
struct OnboardingView: View {
    let model: AppModel
    @State private var refresh = 0

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

            check("Microphone",
                  ok: SetupChecks.microphoneAllowed,
                  detail: SetupChecks.microphoneAllowed
                    ? "Allowed."
                    : "TypeWiser records only while you hold 🌐.") {
                // The prompt only appears while undecided; after a denial
                // the Privacy pane is the only way back.
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        Task { @MainActor in refresh += 1 }
                    }
                } else {
                    openPrivacyPane("Privacy_Microphone")
                }
            }

            if model.settings.sttSource == .apple {
                check("Speech Recognition",
                      ok: SetupChecks.speechAllowed,
                      detail: SetupChecks.speechAllowed
                        ? "Allowed. Transcription runs on this Mac."
                        : "Needed for on-device transcription. Audio is not uploaded.") {
                    if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                        Task {
                            _ = await AppleSpeechTranscriber.requestAuthorization()
                            refresh += 1
                        }
                    } else {
                        openPrivacyPane("Privacy_SpeechRecognition")
                    }
                }
            }

            check("🌐 key is free",
                  ok: SetupChecks.fnIsFree,
                  detail: SetupChecks.fnIsFree
                    ? "Set to Do Nothing."
                    : "Set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, or the emoji picker opens every time you dictate.") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
                )
            }

            if model.mode == .onDevice {
                appleIntelligenceRow
            }

            Button("Re-check") { refresh += 1 }
        }
        .formStyle(.grouped)
        .id(refresh)
        // Most fixes happen in System Settings; re-read on the way back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh += 1
        }
    }

    /// Optional, so it's an info row with no warning triangle: without it
    /// cleanup still runs, just on the built-in rules.
    @ViewBuilder
    private var appleIntelligenceRow: some View {
        let status = OnDeviceRewriter.modelStatus
        let (detail, canFix): (String, Bool) = switch status {
        case .available:
            ("Cleanup uses Apple’s on-device model. Nothing leaves your Mac.", false)
        case .downloading:
            ("Apple Intelligence is still downloading. Until it’s ready, cleanup uses basic built-in rules.", false)
        case .notEnabled:
            ("Optional. Turn it on for smarter cleanup — self-corrections, grammar. Until then, basic built-in rules run.", true)
        case .unsupported:
            ("Not available on this Mac. Cleanup uses basic built-in rules; for more, pick Local or Cloud in the menu.", false)
        }
        Section {
            HStack(alignment: .top) {
                Image(systemName: status == .available ? "checkmark.circle.fill" : "info.circle.fill")
                    .foregroundStyle(status == .available ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Intelligence").font(.body)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if canFix {
                    Button("Open…") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
                        )
                    }
                }
            }
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        )
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
