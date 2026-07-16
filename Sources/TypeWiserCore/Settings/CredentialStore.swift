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
