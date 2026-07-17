import Foundation
import Testing
@testable import TypeWiserCore

// NOTE: uses a throwaway service name so it never touches real credentials.
private func store() -> KeychainCredentialStore {
    KeychainCredentialStore(service: "xyz.crevn.typewiser.tests")
}

// Dummy values only — never put real AWS keys in a test.
private let dummy = AWSCredentials(accessKeyID: "AKIA_TEST_ONLY",
                                   secretAccessKey: "secret_test_only",
                                   region: "ap-south-1")

// Serialized: all three tests share one Keychain service/account, so running
// them concurrently (Swift Testing's default) would let one test's save/delete
// stomp on another's in-flight assertion. `.serialized` forces them to run
// one at a time instead of weakening the shared-service setup.
@Suite(.serialized)
struct CredentialStoreTests {
    @Test func saveThenLoadRoundTrips() throws {
        let s = store()
        try? s.delete()
        try s.save(dummy)
        #expect(s.load() == dummy)
        try s.delete()
    }

    @Test func loadReturnsNilWhenAbsent() throws {
        let s = store()
        try? s.delete()
        #expect(s.load() == nil)
    }

    @Test func saveOverwritesExisting() throws {
        let s = store()
        try? s.delete()
        try s.save(dummy)
        let updated = AWSCredentials(accessKeyID: "AKIA_TEST_2", secretAccessKey: "s2", region: "us-east-1")
        try s.save(updated)
        #expect(s.load() == updated)
        try s.delete()
    }
}

// Per-provider API-key store (OpenAI / Anthropic). Same throwaway service so it
// never touches real keys; serialized for the same shared-Keychain-item reason.
private func keyStore(_ p: KeychainAPIKeyStore.Provider) -> KeychainAPIKeyStore {
    KeychainAPIKeyStore(provider: p, service: "xyz.crevn.typewiser.tests")
}

@Suite(.serialized)
struct APIKeyStoreTests {
    @Test func saveLoadDeleteRoundTrips() throws {
        let s = keyStore(.openai)
        try? s.delete()
        #expect(s.load() == nil)
        try s.save("sk-test-123")
        #expect(s.load() == "sk-test-123")
        try s.delete()
        #expect(s.load() == nil)
    }

    // The two providers must not collide — each keys its own Keychain account.
    @Test func providersAreStoredIndependently() throws {
        let openai = keyStore(.openai)
        let anthropic = keyStore(.anthropic)
        try? openai.delete(); try? anthropic.delete()
        try openai.save("sk-openai")
        try anthropic.save("sk-ant")
        #expect(openai.load() == "sk-openai")
        #expect(anthropic.load() == "sk-ant")
        try openai.delete()
        #expect(openai.load() == nil)
        #expect(anthropic.load() == "sk-ant", "deleting one provider must not affect the other")
        try anthropic.delete()
    }
}
