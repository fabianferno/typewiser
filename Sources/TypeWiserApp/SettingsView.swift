import SwiftUI
import TypeWiserCore

/// Minimal placeholder so `TypeWiserApp`'s `Settings` scene and `SettingsLink`
/// compile and open something. Task 17 owns the real settings UI (rewrite
/// option toggles, name dictionary editor, AWS credential entry, etc.).
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TypeWiser").font(.title2.bold())
            Text("Settings are not implemented yet.")
                .foregroundStyle(.secondary)
            Text("Version \(TypeWiser.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 320)
    }
}
