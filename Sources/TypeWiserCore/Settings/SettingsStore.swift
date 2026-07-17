import Foundation

public enum EngineMode: String, Codable, Sendable {
    case local, cloud
}

/// Non-secret preferences. AWS credentials deliberately do NOT live here —
/// see `KeychainCredentialStore`.
public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private enum Key {
        static let options = "typewiser.options"
        static let mode = "typewiser.mode"
        static let names = "typewiser.nameDictionary"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var options: RewriteOptions {
        get {
            guard let data = defaults.data(forKey: Key.options),
                  let decoded = try? JSONDecoder().decode(RewriteOptions.self, from: data)
            else { return .default }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.options)
        }
    }

    public var mode: EngineMode {
        get { EngineMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .local }
        set { defaults.set(newValue.rawValue, forKey: Key.mode) }
    }

    public var nameDictionary: [String] {
        get { defaults.stringArray(forKey: Key.names) ?? [] }
        set { defaults.set(newValue, forKey: Key.names) }
    }
}
