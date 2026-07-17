import Foundation

public enum EngineMode: String, Codable, Sendable {
    case local, cloud
}

/// Where speech-to-text runs. `apple` uses the on-device Speech framework — no
/// server, no model download, works offline after the first use — and is the
/// default so a fresh install transcribes out of the box. `remote` posts audio
/// to a whisper.cpp-compatible `/inference` endpoint the user configures.
public enum STTSource: String, Codable, Sendable {
    case apple, remote
}

/// Non-secret preferences. AWS credentials deliberately do NOT live here —
/// see `KeychainCredentialStore`.
public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private enum Key {
        static let options = "typewiser.options"
        static let mode = "typewiser.mode"
        static let names = "typewiser.nameDictionary"
        static let sttSource = "typewiser.sttSource"
        static let whisperEndpoint = "typewiser.whisperEndpoint"
        static let llamaBinaryPath = "typewiser.llamaBinaryPath"
        static let modelPath = "typewiser.modelPath"
        static let draftModelPath = "typewiser.draftModelPath"
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

    public var sttSource: STTSource {
        get { STTSource(rawValue: defaults.string(forKey: Key.sttSource) ?? "") ?? .apple }
        set { defaults.set(newValue.rawValue, forKey: Key.sttSource) }
    }

    /// A whisper.cpp-compatible `/inference` URL, used only when `sttSource`
    /// is `.remote`. Empty by default — there is no built-in server to point at.
    public var whisperEndpoint: String {
        get { defaults.string(forKey: Key.whisperEndpoint) ?? "" }
        set { defaults.set(newValue, forKey: Key.whisperEndpoint) }
    }

    // Each engine path falls back to `EngineConfig.gemmaDefault` so an existing
    // local setup keeps working untouched, while a fresh clone can retarget the
    // binary/model without recompiling. Read them through `engineConfig`.
    public var llamaBinaryPath: String {
        get { defaults.string(forKey: Key.llamaBinaryPath) ?? EngineConfig.gemmaDefault.binaryPath }
        set { defaults.set(newValue, forKey: Key.llamaBinaryPath) }
    }

    public var modelPath: String {
        get { defaults.string(forKey: Key.modelPath) ?? EngineConfig.gemmaDefault.modelPath }
        set { defaults.set(newValue, forKey: Key.modelPath) }
    }

    public var draftModelPath: String {
        get { defaults.string(forKey: Key.draftModelPath) ?? EngineConfig.gemmaDefault.draftModelPath }
        set { defaults.set(newValue, forKey: Key.draftModelPath) }
    }

    public var engineConfig: EngineConfig {
        EngineConfig(binaryPath: llamaBinaryPath,
                     modelPath: modelPath,
                     draftModelPath: draftModelPath)
    }
}
