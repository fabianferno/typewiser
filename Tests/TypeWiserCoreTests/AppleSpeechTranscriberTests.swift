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

/// The recognizer reports a missing on-device model as an untyped `NSError`
/// whose useful detail ("No Assistant asset for language en-GB") is buried in
/// a nested `UserInfo`. Left unclassified it reached the HUD verbatim; it must
/// become a case the message layer can phrase, tagged with the locale that is
/// actually missing rather than whatever the error mentions.
@Test func missingAssetErrorsClassifyAsModelNotInstalled() {
    let underlying = NSError(domain: "kLSRErrorDomain", code: 101,
                             userInfo: [NSLocalizedDescriptionKey: "No Assistant asset for language en-GB"])
    let raised = NSError(domain: "kLSRErrorDomain", code: 102,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to access assets",
                                    NSUnderlyingErrorKey: underlying])

    let classified = AppleSpeechTranscriber.classify(raised, locale: "en_GB")
    #expect(classified as? AppleSpeechError == .modelNotInstalled(locale: "en_GB"))
    // The bare 101 arrives on its own in some failures, not only nested.
    #expect(AppleSpeechTranscriber.classify(underlying, locale: "en_GB") as? AppleSpeechError
            == .modelNotInstalled(locale: "en_GB"))
}

/// Classification must not swallow the failure it already had a case for, nor
/// invent one for errors it does not recognise — those still carry their own
/// description to the HUD.
@Test func classifyLeavesOtherErrorsAlone() {
    let noSpeech = NSError(domain: "kAFAssistantErrorDomain", code: 1110)
    #expect(AppleSpeechTranscriber.classify(noSpeech, locale: "en_GB") as? AppleSpeechError == .noSpeechDetected)

    let unrelated = NSError(domain: "SomeOtherDomain", code: 102)
    #expect(AppleSpeechTranscriber.classify(unrelated, locale: "en_GB") as? AppleSpeechError == nil)
}
