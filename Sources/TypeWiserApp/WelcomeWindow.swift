import AppKit
import SwiftUI

/// Shown at launch while anything dictation needs is still missing. A menu-bar
/// agent has no Dock icon and no window, so without this a first-time user
/// sees a tiny waveform glyph and nothing telling them what to do next.
@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let host = NSHostingController(rootView: WelcomeView(model: model) { [weak self] in
                self?.window?.close()
            })
            let w = NSWindow(contentViewController: host)
            w.title = "Welcome to TypeWiser"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // An `LSUIElement` app is never active on its own; without this the
        // window opens behind whatever the user was doing.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct WelcomeView: View {
    let model: AppModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 64, height: 64)
                Text("Hold 🌐, speak, release.").font(.title2.weight(.semibold))
                Text("A few things to allow first. Each one takes a click.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.top, 20)

            OnboardingView(model: model)

            HStack {
                Text("TypeWiser lives in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480, height: 600)
    }
}
