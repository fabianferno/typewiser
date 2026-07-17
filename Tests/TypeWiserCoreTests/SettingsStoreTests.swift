import Foundation
import Testing
@testable import TypeWiserCore

private func freshDefaults() -> UserDefaults {
    let name = "tw-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@Test func defaultsHaveAllRulesOnAndLocalMode() {
    let s = SettingsStore(defaults: freshDefaults())
    #expect(s.options == RewriteOptions.default)
    #expect(s.mode == .local)
    #expect(s.nameDictionary.isEmpty)
}

@Test func optionsRoundTripThroughDefaults() {
    let d = freshDefaults()
    var o = RewriteOptions.default
    o.fixGrammar = false
    SettingsStore(defaults: d).options = o
    #expect(SettingsStore(defaults: d).options.fixGrammar == false)
}

@Test func modeRoundTrips() {
    let d = freshDefaults()
    SettingsStore(defaults: d).mode = .cloud
    #expect(SettingsStore(defaults: d).mode == .cloud)
}

@Test func nameDictionaryRoundTrips() {
    let d = freshDefaults()
    SettingsStore(defaults: d).nameDictionary = ["Crevn", "Fabian Ferno"]
    #expect(SettingsStore(defaults: d).nameDictionary == ["Crevn", "Fabian Ferno"])
}

@Test func corruptDefaultsFallBackToDefaults() {
    let d = freshDefaults()
    d.set(Data("garbage".utf8), forKey: "typewiser.options")
    #expect(SettingsStore(defaults: d).options == RewriteOptions.default)
}
