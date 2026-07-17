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
