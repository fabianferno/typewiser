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
    func sendCommandV() {
        sent += 1
        pasteboardAtSendTime = pb?.current
    }
}

@Test func insertSetsPastesAndRestoresInOrder() async {
    let pb = FakePasteboard(), keys = FakeKeys()
    keys.pb = pb
    let inj = TextInjector(pasteboard: pb, keys: keys, restoreDelay: .milliseconds(1))
    await inj.insert("hello")
    #expect(keys.sent == 1)
    #expect(pb.log == ["snapshot", "set:hello", "restore"])
}

@Test func textIsOnPasteboardAtTheMomentCommandVFires() async {
    let pb = FakePasteboard(), keys = FakeKeys()
    keys.pb = pb
    let inj = TextInjector(pasteboard: pb, keys: keys, restoreDelay: .milliseconds(1))
    await inj.insert("hello")
    #expect(keys.pasteboardAtSendTime == "hello", "must not restore before the paste lands")
}

@Test func originalClipboardIsRestoredAfterwards() async {
    let pb = FakePasteboard(), keys = FakeKeys()
    keys.pb = pb
    let inj = TextInjector(pasteboard: pb, keys: keys, restoreDelay: .milliseconds(1))
    await inj.insert("hello")
    #expect(pb.current == "ORIGINAL")
}

@Test func emptyTextIsANoOp() async {
    let pb = FakePasteboard(), keys = FakeKeys()
    keys.pb = pb
    let inj = TextInjector(pasteboard: pb, keys: keys, restoreDelay: .milliseconds(1))
    await inj.insert("")
    #expect(keys.sent == 0)
    #expect(pb.log.isEmpty)
}
