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
    // fallback: "x" is unquoted, so the raw transcript gives no evidence the quotes
    // were part of what the speaker said — they're model noise and should be stripped.
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

@Test func sanitizeFallsBackOnEmptyOutputAfterStripping() {
    // Even once an artifact (here, a code fence) is peeled away leaving nothing,
    // the loop must still fall back to the raw transcript — never silence.
    #expect(RewritePrompt.sanitize("```\n\n```", fallback: "raw words") == "raw words")
}

@Test func sanitizeLeavesCleanTextAlone() {
    #expect(RewritePrompt.sanitize("Let's meet at 3.", fallback: "x") == "Let's meet at 3.")
}

@Test func sanitizeStripsCombinedPreambleAndFence() {
    // Finding 1: preamble wraps a fenced block. A single fixed pass leaves the
    // preamble stripped but the fence markers behind (or vice versa) because the
    // fence check only fires when the WHOLE trimmed string starts with ```.
    // Looping to a fixed point must remove both.
    let out = RewritePrompt.sanitize(
        "Here's the cleaned text:\n```\nLet's meet at 3.\n```",
        fallback: "x"
    )
    #expect(out == "Let's meet at 3.")
}

@Test func sanitizeStripsQuoteWrappedPreamble() {
    // Finding 1: the whole preamble+body is wrapped in quotes, so on the first pass
    // the preamble line still has a leading `"` and `hasPrefix("here")` fails.
    // Stripping the quotes must reveal the preamble so a later pass can remove it.
    let out = RewritePrompt.sanitize(
        "\"Here's the cleaned text:\nLet's meet at 3.\"",
        fallback: "x"
    )
    #expect(out == "Let's meet at 3.")
}

@Test func sanitizeKeepsQuotesWhenTranscriptWasAlsoQuoted() {
    // Finding 3: quote stripping is ambiguous on its own — dictating an actual
    // quotation looks identical to a model adding quotes. Use the raw transcript
    // (fallback) as evidence: if it was ALSO quoted, the speaker meant the quotes,
    // so keep them rather than strip.
    let out = RewritePrompt.sanitize("\"Let's meet at 3.\"", fallback: "\"Let's meet at 3.\"")
    #expect(out == "\"Let's meet at 3.\"")
}

@Test func sanitizeStripsQuotesWhenTranscriptWasUnquoted() {
    // Finding 3: transcript unquoted + output quoted means the model added the
    // quotes itself, so they're safe to strip.
    let out = RewritePrompt.sanitize("\"Let's meet at 3.\"", fallback: "Let's meet at 3.")
    #expect(out == "Let's meet at 3.")
}
