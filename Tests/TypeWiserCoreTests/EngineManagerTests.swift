import Testing
@testable import TypeWiserCore

@Test func defaultConfigPointsAtRealPaths() {
    let c = EngineConfig.gemmaDefault
    #expect(c.binaryPath.hasSuffix("build/bin/llama-server"))
    #expect(c.modelPath.hasSuffix("gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf"))
    #expect(c.draftModelPath.hasSuffix("gemma-4-26B-A4B-it-Q8_0-MTP.gguf"))
}

@Test func portIs8231Not8080() {
    #expect(EngineConfig.gemmaDefault.port == 8231, "8080 is commonly occupied")
}

@Test func contextIsTrimmedTo4096() {
    #expect(EngineConfig.gemmaDefault.contextSize == 4096,
            "prompts are one short utterance; 65536 wastes GBs of KV cache")
}

@Test func argumentsOmitMmprojBecauseWeDoNotDoVision() async {
    let args = await EngineManager().arguments()
    #expect(!args.contains("--mmproj"), "vision projector is unused for text rewriting")
}

@Test func argumentsIncludeModelDraftAndSpecDecoding() async {
    let args = await EngineManager().arguments()
    #expect(args.contains("--model-draft"))
    #expect(args.contains("--spec-type"))
    #expect(args.contains("draft-mtp"))
}

@Test func argumentsBindLocalhostOnConfiguredPort() async {
    let args = await EngineManager().arguments()
    let portIdx = args.firstIndex(of: "--port")!
    #expect(args[portIdx + 1] == "8231")
    let hostIdx = args.firstIndex(of: "--host")!
    #expect(args[hostIdx + 1] == "127.0.0.1")
}

@Test func startsStopped() async {
    #expect(await EngineManager().state == .stopped)
}
