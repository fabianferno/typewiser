import Foundation

/// Where cleanup runs. `onDevice` (Apple Intelligence, with built-in rules
/// underneath — see `OnDeviceRewriter`) is the default because it needs no
/// setup: `local` wants a ~17GB llama.cpp model and `cloud` wants an API key.
public enum EngineMode: String, Codable, Sendable {
    case onDevice, local, cloud
}

/// Which hosted LLM cleans up the transcript when the engine is set to Cloud.
/// `bedrock` is the original AWS path; `openai` and `anthropic` call those
/// providers' APIs directly with a user-supplied key.
public enum CloudProvider: String, Codable, Sendable, CaseIterable {
    case bedrock, openai, anthropic
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
        static let cloudProvider = "typewiser.cloudProvider"
        static let sttLocale = "typewiser.sttLocale"
        static let openAIModel = "typewiser.openAIModel"
        static let anthropicModel = "typewiser.anthropicModel"
        static let soundsEnabled = "typewiser.soundsEnabled"
    }

    public static let defaultOpenAIModel = "gpt-4o-mini"
    public static let defaultAnthropicModel = "claude-haiku-4-5"

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

    /// The audible cues: Morse when text is pasted, Ping when the hotkey was
    /// released before anything could be captured. On by default — the HUD is
    /// often behind the window the user is typing into, so sound is the only
    /// feedback they reliably get. `object(forKey:)` rather than
    /// `bool(forKey:)` because the latter can't tell "never set" (which must
    /// mean on) from an explicit off.
    public var soundsEnabled: Bool {
        get { defaults.object(forKey: Key.soundsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.soundsEnabled) }
    }

    public var mode: EngineMode {
        get { EngineMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .onDevice }
        set { defaults.set(newValue.rawValue, forKey: Key.mode) }
    }

    public var nameDictionary: [String] {
        get { defaults.stringArray(forKey: Key.names) ?? [] }
        set { defaults.set(newValue, forKey: Key.names) }
    }

    /// English locales Apple's Speech framework recognises, offered in Settings.
    /// Accent match matters more than it looks: an `en_US` acoustic model hearing
    /// an Indian-English speaker mishears in a characteristic way ("launch" ->
    /// "lunch", "churn" -> "sure"), which reads as a broken app rather than a
    /// mismatched model.
    public static let supportedSTTLocales = [
        "en_US", "en_IN", "en_GB", "en_AU", "en_CA", "en_IE", "en_NZ", "en_ZA",
    ]

    /// Which acoustic model transcribes. Defaults to the system locale when the
    /// framework has a recognizer for it, so a machine set to English (India)
    /// gets the matching model without the user knowing this setting exists;
    /// falls back to `en_US` otherwise. A stored value that is no longer
    /// supported falls back too, rather than handing the transcriber a locale
    /// with no recognizer behind it.
    public var sttLocale: String {
        get {
            let stored = defaults.string(forKey: Key.sttLocale) ?? ""
            if Self.supportedSTTLocales.contains(stored) { return stored }
            return Self.systemDefaultSTTLocale
        }
        set { defaults.set(newValue, forKey: Key.sttLocale) }
    }

    public static var systemDefaultSTTLocale: String {
        let system = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
        if supportedSTTLocales.contains(system) { return system }
        // Region-qualified identifiers can carry extra subtags (en_IN@calendar=…);
        // match on the leading language_region pair before giving up.
        let parts = system.split(separator: "@").first.map(String.init) ?? system
        if supportedSTTLocales.contains(parts) { return parts }
        return "en_US"
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

    public var cloudProvider: CloudProvider {
        get { CloudProvider(rawValue: defaults.string(forKey: Key.cloudProvider) ?? "") ?? .bedrock }
        set { defaults.set(newValue.rawValue, forKey: Key.cloudProvider) }
    }

    public var openAIModel: String {
        get {
            let v = defaults.string(forKey: Key.openAIModel) ?? ""
            return v.isEmpty ? Self.defaultOpenAIModel : v
        }
        set { defaults.set(newValue, forKey: Key.openAIModel) }
    }

    public var anthropicModel: String {
        get {
            let v = defaults.string(forKey: Key.anthropicModel) ?? ""
            return v.isEmpty ? Self.defaultAnthropicModel : v
        }
        set { defaults.set(newValue, forKey: Key.anthropicModel) }
    }
}
