import SwiftUI

@main
struct TypeWiserApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("TypeWiser", systemImage: menuIcon) {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }

    private var menuIcon: String {
        if case .recording = model.phase { return "waveform.circle.fill" }
        return "waveform"
    }
}
