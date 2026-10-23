import Foundation
import Sparkle

/// Sparkle, but only in a release build. `release.sh` writes `SUFeedURL` and
/// `SUPublicEDKey` into the bundle; a dev build from `bundle-app.sh` has
/// neither, and starting Sparkle without a key makes it show an error dialog
/// on every launch. So the updater simply doesn't exist there.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        controller = key.isEmpty || feed.isEmpty
            ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
