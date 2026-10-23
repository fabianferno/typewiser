import Testing
@testable import TypeWiserCore

private func clean(_ s: String,
                   options: RewriteOptions = .default,
                   context: RewriteContext = .empty) async throws -> String {
    try await RuleBasedRewriter().rewrite(s, options: options, context: context)
}

@Test func ruleBasedRemovesNonLexicalFillers() async throws {
    #expect(try await clean("um so I think uh we should ship it") == "So I think we should ship it.")
}

@Test func ruleBasedDropsTheCommaAFillerLeavesBehind() async throws {
    #expect(try await clean("So, um, we should ship it.") == "So, we should ship it.")
    #expect(try await clean("Uh, yes.") == "Yes.")
}

@Test func ruleBasedKeepsFillersWhenDisabled() async throws {
    var o = RewriteOptions.default
    o.removeFillers = false
    #expect(try await clean("um yes", options: o) == "Um yes.")
}

@Test func ruleBasedLeavesLexicalWordsThatLookLikeFillers() async throws {
    // "like" and "you know" carry meaning often enough that a rule can't tell —
    // only the LLM engines are trusted to judge them.
    #expect(try await clean("I like it, you know") == "I like it, you know.")
    // Fillers are matched as whole words, never inside one.
    #expect(try await clean("the umbrella is here") == "The umbrella is here.")
}

@Test func ruleBasedCollapsesStutteredWords() async throws {
    #expect(try await clean("I I think the the plan works") == "I think the plan works.")
}

@Test func ruleBasedKeepsRepetitionWhenDisabled() async throws {
    var o = RewriteOptions.default
    o.removeRepetition = false
    #expect(try await clean("the the plan", options: o) == "The the plan.")
}

@Test func ruleBasedCapitalisesSentencesAndTheWordI() async throws {
    #expect(try await clean("i think so. then i left") == "I think so. Then I left.")
}

@Test func ruleBasedKeepsExistingTerminalPunctuation() async throws {
    #expect(try await clean("are you coming?") == "Are you coming?")
    #expect(try await clean("wow!") == "Wow!")
}

@Test func ruleBasedLeavesCasingAndPunctuationAloneWhenGrammarDisabled() async throws {
    var o = RewriteOptions.default
    o.fixGrammar = false
    #expect(try await clean("um i think so", options: o) == "i think so")
}

@Test func ruleBasedSpellsDictionaryNames() async throws {
    let ctx = RewriteContext(nameDictionary: ["Priyanka", "PostgreSQL", "gRPC"])
    #expect(try await clean("ask priyanka about postgresql and grpc", context: ctx)
            == "Ask Priyanka about PostgreSQL and gRPC.")
}

@Test func ruleBasedIgnoresDictionaryWhenSpellingDisabled() async throws {
    var o = RewriteOptions.default
    o.contextAwareSpelling = false
    let ctx = RewriteContext(nameDictionary: ["gRPC"])
    #expect(try await clean("use grpc", options: o, context: ctx) == "Use grpc.")
}

@Test func ruleBasedNeverReturnsEmpty() async throws {
    // A dictation that was nothing but filler is still something the user said.
    #expect(try await clean("um") == "um")
}

@Test func ruleBasedIsIdentityWhenEverythingDisabled() async throws {
    var o = RewriteOptions.default
    o.removeFillers = false; o.fixGrammar = false; o.removeRepetition = false
    o.resolveSelfCorrections = false; o.contextAwareSpelling = false
    #expect(try await clean("um i i think", options: o) == "um i i think")
}
