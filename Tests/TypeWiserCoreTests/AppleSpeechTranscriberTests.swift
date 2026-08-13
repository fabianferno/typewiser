import Foundation
import Testing
@testable import TypeWiserCore

@Test func transcriberAcceptsALocaleAndVocabulary() {
    // The name dictionary previously reached only the rewrite prompt, which can
    // fix spelling but cannot recover a word the recognizer never heard.
    // `contextualStrings` biases recognition itself, so the hint has to get this far.
    let t = AppleSpeechTranscriber(locale: Locale(identifier: "en_IN"),
                                   vocabulary: ["Crevn", "churn"])
    #expect(t.localeIdentifier == "en_IN")
    #expect(t.vocabulary == ["Crevn", "churn"])
}

@Test func transcriberDefaultsRemainUsableWithNoVocabulary() {
    let t = AppleSpeechTranscriber()
    #expect(t.vocabulary.isEmpty)
}
