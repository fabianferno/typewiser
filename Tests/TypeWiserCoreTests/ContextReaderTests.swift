import Testing
@testable import TypeWiserCore

@Test func trimKeepsTailBecauseCursorIsAtTheEnd() {
    let out = AXContextReader.trimContext("aaaaabbbbbccccc", maxChars: 5)
    #expect(out == "ccccc")
}

@Test func trimLeavesShortTextAlone() {
    #expect(AXContextReader.trimContext("hi", maxChars: 600) == "hi")
}

@Test func trimHandlesEmpty() {
    #expect(AXContextReader.trimContext("", maxChars: 600) == "")
}

@Test func readNeverCrashesWithoutAXPermission() {
    // In CI/headless there is no focused element; must degrade, not trap.
    let ctx = AXContextReader(nameDictionary: ["Crevn"]).read()
    #expect(ctx.nameDictionary == ["Crevn"], "dictionary must survive AX returning nothing")
}
