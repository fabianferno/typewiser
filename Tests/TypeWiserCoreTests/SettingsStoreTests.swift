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

@Test func speechToTextDefaultsToOnDeviceApple() {
    let s = SettingsStore(defaults: freshDefaults())
    #expect(s.sttSource == .apple, "fresh installs must transcribe locally with no server to configure")
    #expect(s.whisperEndpoint.isEmpty)
}

@Test func sttSourceAndEndpointRoundTrip() {
    let d = freshDefaults()
    let s = SettingsStore(defaults: d)
    s.sttSource = .remote
    s.whisperEndpoint = "https://example.test/inference"
    let reloaded = SettingsStore(defaults: d)
    #expect(reloaded.sttSource == .remote)
    #expect(reloaded.whisperEndpoint == "https://example.test/inference")
}

// The engine paths default to whatever `EngineConfig.gemmaDefault` resolves to
// on this machine, so an existing local setup keeps working without touching
// Settings — and a fresh clone can point these anywhere without a rebuild.
@Test func engineConfigDefaultsToGemmaDefaultButIsOverridable() {
    let d = freshDefaults()
    #expect(SettingsStore(defaults: d).engineConfig == EngineConfig.gemmaDefault)

    let s = SettingsStore(defaults: d)
    s.modelPath = "/models/custom.gguf"
    s.llamaBinaryPath = "/opt/llama/llama-server"
    let cfg = SettingsStore(defaults: d).engineConfig
    #expect(cfg.modelPath == "/models/custom.gguf")
    #expect(cfg.binaryPath == "/opt/llama/llama-server")
    #expect(cfg.draftModelPath == EngineConfig.gemmaDefault.draftModelPath,
            "an untouched field must keep falling back to the default")
}

@Test func cloudProviderDefaultsToBedrockAndRoundTrips() {
    let d = freshDefaults()
    #expect(SettingsStore(defaults: d).cloudProvider == .bedrock,
            "Bedrock is the original cloud path; keep it the default")
    SettingsStore(defaults: d).cloudProvider = .anthropic
    #expect(SettingsStore(defaults: d).cloudProvider == .anthropic)
}

@Test func cloudModelsDefaultToSmallFastModelsAndOverride() {
    let d = freshDefaults()
    #expect(SettingsStore(defaults: d).openAIModel == SettingsStore.defaultOpenAIModel)
    #expect(SettingsStore(defaults: d).anthropicModel == SettingsStore.defaultAnthropicModel)

    let s = SettingsStore(defaults: d)
    s.openAIModel = "gpt-5"
    s.anthropicModel = "claude-opus-4-8"
    #expect(SettingsStore(defaults: d).openAIModel == "gpt-5")
    #expect(SettingsStore(defaults: d).anthropicModel == "claude-opus-4-8")
}
