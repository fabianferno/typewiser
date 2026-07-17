import Foundation
import Security

/// AWS credentials in the macOS Keychain.
///
/// These must never be written to UserDefaults, a plist, a dotfile, or the repo.
public struct KeychainCredentialStore: Sendable {
    public enum KeychainError: Error, Equatable { case status(OSStatus) }

    private let service: String
    private let account = "aws"

    public init(service: String = "xyz.crevn.typewiser") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func save(_ credentials: AWSCredentials) throws {
        let payload = try JSONEncoder().encode(
            ["accessKeyID": credentials.accessKeyID,
             "secretAccessKey": credentials.secretAccessKey,
             "region": credentials.region]
        )
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = payload
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func load() -> AWSCredentials? {
        var get = query
        get[kSecReturnData as String] = true
        get[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(get as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let dict = try? JSONDecoder().decode([String: String].self, from: data),
              let key = dict["accessKeyID"], let secret = dict["secretAccessKey"], let region = dict["region"]
        else { return nil }
        return AWSCredentials(accessKeyID: key, secretAccessKey: secret, region: region)
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}

/// A single API-key string in the macOS Keychain, one keychain item per
/// provider. Used for the OpenAI and Anthropic cleanup backends; AWS keeps its
/// own multi-field store above. Same rule applies: keys never touch
/// UserDefaults, a plist, a dotfile, or the repo.
public struct KeychainAPIKeyStore: Sendable {
    public enum Provider: String, Sendable, CaseIterable { case openai, anthropic }
    public enum KeychainError: Error, Equatable { case status(OSStatus) }

    private let service: String
    private let account: String

    public init(provider: Provider, service: String = "xyz.crevn.typewiser") {
        self.service = service
        self.account = "apikey.\(provider.rawValue)"
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func save(_ key: String) throws {
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func load() -> String? {
        var get = query
        get[kSecReturnData as String] = true
        get[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(get as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}
