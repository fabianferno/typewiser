import Foundation
import Testing
@testable import TypeWiserCore

final class FakePasteboard: Pasteboarding, @unchecked Sendable {
    var current = "ORIGINAL"
    var log: [String] = []
    func snapshot() -> [[String: Data]] {
        log.append("snapshot")
        return [["public.utf8-plain-text": Data(current.utf8)]]
    }
    func set(string: String) {
        log.append("set:\(string)")
        current = string
    }
    func restore(_ snapshot: [[String: Data]]) {
        log.append("restore")
        if let d = snapshot.first?["public.utf8-plain-text"] {
            current = String(decoding: d, as: UTF8.self)
        }
    }
}

final class FakeKeys: KeystrokeSending, @unchecked Sendable {
    var sent = 0
    var pasteboardAtSendTime: String?
    var pb: FakePasteboard?

    /// How long the simulated target app takes, after ⌘V is delivered, to
    /// actually get around to reading the pasteboard and performing its
    /// paste. Real apps paste asynchronously — modeling `sendCommandV()` as
    /// instantaneous (as the base fake does when this is nil) can't exercise
    /// the restore-delay race at all, which is exactly what let the missing
    /// `Task.sleep` slip through review undetected.
    var pasteLatency: Duration?
    /// What the simulated target app observed on the pasteboard when its
    /// (delayed) paste actually happened.
    private(set) var pastedValue: String?
    private var pasteTask: Task<Void, Never>?

    func sendCommandV() {
        sent += 1
        pasteboardAtSendTime = pb?.current
        if let pasteLatency {
            let pb = self.pb
            pasteTask = Task.detached { [weak self] in
                try? await Task.sleep(for: pasteLatency)
                let value = pb?.current
                self?.pastedValue = value
            }
        }
    }

    /// Deterministically wait for the simulated target app's asynchronous
    /// paste (if `pasteLatency` scheduled one) to finish reading the
    /// pasteboard, so tests never have to sleep-and-hope.
    func awaitSimulatedPaste() async {
        await pasteTask?.value
    }
}

final class FakeSound: SoundPlaying, @unchecked Sendable {
    private(set) var plays = 0
    func play() { plays += 1 }
}

@Test func insertSetsPastesAndRestoresInOrder() async {
    let pb = FakePasteboard(), keys = FakeKeys()
    keys.pb = pb
    let inj = TextInjector(pasteboard: pb, keys: keys, restoreDelay: .milliseconds(1), sound: nil)
    await inj.insert("hello")
    #expect(keys.sent == 1)
    #expect(pb.log == ["snapshot", "set:hello", "restore"])
}

@Test func insertPlaysTheCueOncePerPaste() async {
    let pb = FakePasteboard(), keys = FakeKeys(), sound = FakeSound()
    keys.pb = pb
    let inj = TextInjector(pasteboard: pb, keys: keys, restoreDelay: .milliseconds(1), sound: sound)
    await inj.insert("hello")
    #expect(sound.plays == 1)
}

/// Nothing was pasted, so nothing should be heard — an empty insert returns
/// before touching the pasteboard and must stay equally silent.
@Test func emptyInsertPlaysNoCue() async {
    let sound = FakeSound()
    let inj = TextInjector(pasteboard: FakePasteboard(), keys: FakeKeys(),
                           restoreDelay: .milliseconds(1), sound: sound)
    await inj.insert("")
    #expect(sound.plays == 0)
}

@Test func textIsOnPasteboardAtTheMomentCommandVFires() async {
    let pb = FakePasteboard(), keys = FakeKeys()
    keys.pb = pb
    let inj = TextInjector(pasteboard: pb, keys: keys, restoreDelay: .milliseconds(1), sound: nil)
    await inj.insert("hello")
    #expect(keys.pasteboardAtSendTime == "hello", "must not restore before the paste lands")
}

@Test func originalClipboardIsRestoredAfterwards() async {
    let pb = FakePasteboard(), keys = FakeKeys()
    keys.pb = pb
    let inj = TextInjector(pasteboard: pb, keys: keys, restoreDelay: .milliseconds(1), sound: nil)
    await inj.insert("hello")
    #expect(pb.current == "ORIGINAL")
}

@Test func emptyTextIsANoOp() async {
    let pb = FakePasteboard(), keys = FakeKeys()
    keys.pb = pb
    let inj = TextInjector(pasteboard: pb, keys: keys, restoreDelay: .milliseconds(1), sound: nil)
    await inj.insert("")
    #expect(keys.sent == 0)
    #expect(pb.log.isEmpty)
}

// MARK: - Guarding `try? await Task.sleep(for: restoreDelay)`
//
// The four tests above all use a synchronous `FakeKeys.sendCommandV()`, which
// always observes the pasteboard before `insert()` gets anywhere near
// restoring it — regardless of whether `restoreDelay` is honored, or even
// present at all. That means none of them would notice if the load-bearing
// `try? await Task.sleep(for: restoreDelay)` line in TextInjector.insert(_:)
// were deleted outright. In production that line is the only thing standing
// between the user's dictated text and a silent paste of their OLD clipboard
// contents, so an unguarded regression here is a real, user-facing bug.
//
// The two tests below give `FakeKeys` a simulated *asynchronous* paste (via
// `pasteLatency`), modeling how a real target app doesn't read the
// pasteboard until some time after ⌘V is delivered. `pasteObserves...`
// deterministically awaits that simulated paste (`awaitSimulatedPaste()`)
// instead of sleeping-and-hoping, so there is no flakiness window.

@Test func pasteObservesDictatedTextWhenRestoreDelayIsSufficient() async {
    let pb = FakePasteboard(), keys = FakeKeys()
    keys.pb = pb
    keys.pasteLatency = .milliseconds(50)
    let inj = TextInjector(pasteboard: pb, keys: keys, restoreDelay: .milliseconds(200), sound: nil)
    await inj.insert("hello")
    await keys.awaitSimulatedPaste()
    // restoreDelay (200ms) comfortably outlasts pasteLatency (50ms), so the
    // simulated app's paste must still see our dictated text.
    //
    // This is the test that goes RED if `try? await Task.sleep(for:
    // restoreDelay)` is deleted from TextInjector.insert(_:): without it,
    // insert() restores the original clipboard immediately after
    // sendCommandV(), so by the time the simulated paste reads the
    // pasteboard 50ms later, it finds "ORIGINAL" instead of "hello".
    #expect(keys.pastedValue == "hello", "clipboard must still hold dictated text when the delayed paste reads it")
}

@Test func pasteRacesOriginalClipboardWhenRestoreDelayIsTooShort() async {
    let pb = FakePasteboard(), keys = FakeKeys()
    keys.pb = pb
    keys.pasteLatency = .milliseconds(50)
    let inj = TextInjector(pasteboard: pb, keys: keys, restoreDelay: .zero, sound: nil)
    await inj.insert("hello")
    await keys.awaitSimulatedPaste()
    // With an insufficient restoreDelay, the clipboard is put back to
    // "ORIGINAL" well before the simulated app's 50ms-delayed paste ever
    // reads it — demonstrating the exact race `restoreDelay` exists to
    // prevent.
    #expect(keys.pastedValue == "ORIGINAL", "an insufficient restore delay must let the race actually happen")
}
