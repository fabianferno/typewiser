import Testing
@testable import TypeWiserCore

@Test func systemPromptOnlyListsEnabledRules() {
    var o = RewriteOptions.default
    o.resolveSelfCorrections = false
    let p = RewritePrompt.system(options: o, context: .empty)
    #expect(p.contains("filler"))
    #expect(!p.lowercased().contains("changes their mind"))
}

@Test func systemPromptForbidsAnsweringTheContent() {
    let p = RewritePrompt.system(options: .default, context: .empty)
    #expect(p.contains("Never answer"))
    #expect(p.contains("Return only"))
}

@Test func contextIsIncludedOnlyWhenSpellingEnabled() {
    let ctx = RewriteContext(surroundingText: "Dear Fabian", appName: "Mail", nameDictionary: ["Crevn"])
    var on = RewriteOptions.default; on.contextAwareSpelling = true
    #expect(RewritePrompt.system(options: on, context: ctx).contains("Crevn"))
    var off = RewriteOptions.default; off.contextAwareSpelling = false
    #expect(!RewritePrompt.system(options: off, context: ctx).contains("Crevn"))
}

@Test func isNoOpWhenEverythingDisabled() {
    var o = RewriteOptions.default
    o.removeFillers = false; o.fixGrammar = false; o.removeRepetition = false
    o.resolveSelfCorrections = false; o.contextAwareSpelling = false
    #expect(o.isNoOp)
    #expect(!RewriteOptions.default.isNoOp)
}

@Test func sanitizeStripsWrappingQuotes() {
    #expect(RewritePrompt.sanitize("\"Let's meet at 3.\"", fallback: "x") == "Let's meet at 3.")
}

@Test func sanitizeStripsPreambleLine() {
    let out = RewritePrompt.sanitize("Here's the cleaned text:\nLet's meet at 3.", fallback: "x")
    #expect(out == "Let's meet at 3.")
}

@Test func sanitizeStripsCodeFences() {
    #expect(RewritePrompt.sanitize("```\nLet's meet at 3.\n```", fallback: "x") == "Let's meet at 3.")
}

@Test func sanitizeFallsBackOnEmptyOutput() {
    #expect(RewritePrompt.sanitize("   \n ", fallback: "raw words") == "raw words",
            "never lose the user's words")
}

@Test func sanitizeLeavesCleanTextAlone() {
    #expect(RewritePrompt.sanitize("Let's meet at 3.", fallback: "x") == "Let's meet at 3.")
}
