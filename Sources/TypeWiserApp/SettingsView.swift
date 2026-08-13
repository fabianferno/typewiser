import SwiftUI
import TypeWiserCore

/// Three tabs: rewrite-rule toggles + name dictionary, AWS credentials
/// (Keychain-backed), and onboarding checks that verify (not merely
/// instruct) the machine is actually set up correctly.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var options = RewriteOptions.default
    @State private var names: [String] = []
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var savedMessage = ""
    @State private var sttSource: STTSource = .apple
    @State private var sttLocale: String = SettingsStore.systemDefaultSTTLocale
    @State private var whisperEndpoint = ""
    @State private var llamaBinaryPath = ""
    @State private var modelPath = ""
    @State private var draftModelPath = ""
    @State private var cloudProvider: CloudProvider = .bedrock
    @State private var openAIKeyField = ""
    @State private var anthropicKeyField = ""
    @State private var openAIModel = ""
    @State private var anthropicModel = ""
    @State private var soundsEnabled = true

    private let credentials = KeychainCredentialStore()
    private let openAIStore = KeychainAPIKeyStore(provider: .openai)
    private let anthropicStore = KeychainAPIKeyStore(provider: .anthropic)

    var body: some View {
        TabView {
            cleanupTab.tabItem { Label("Cleanup", systemImage: "wand.and.sparkles") }
            engineTab.tabItem { Label("Engine", systemImage: "cpu") }
            cloudTab.tabItem { Label("Cloud", systemImage: "cloud") }
            setupTab.tabItem { Label("Setup", systemImage: "checkmark.shield") }
        }
        .frame(width: 460, height: 420)
        .onAppear {
            options = model.settings.options
            names = model.settings.nameDictionary
            sttSource = model.settings.sttSource
            sttLocale = model.settings.sttLocale
            whisperEndpoint = model.settings.whisperEndpoint
            llamaBinaryPath = model.settings.llamaBinaryPath
            modelPath = model.settings.modelPath
            draftModelPath = model.settings.draftModelPath
            cloudProvider = model.settings.cloudProvider
            openAIModel = model.settings.openAIModel
            anthropicModel = model.settings.anthropicModel
            soundsEnabled = model.settings.soundsEnabled
        }
    }

    /// Speech-to-text source and the local llama-server paths for Cleanup's
    /// Local mode. All of these are read once at launch, so the footnote tells
    /// the user a change needs a restart rather than silently doing nothing.
    /// Its own property because inlining the ForEach pushed the Form body past
    /// what the type-checker will solve in reasonable time.
    private var accentPicker: some View {
        Picker("Accent", selection: $sttLocale) {
            ForEach(SettingsStore.supportedSTTLocales, id: \.self) { id in
                Text(localeLabel(id)).tag(id)
            }
        }
    }

    private func localeLabel(_ id: String) -> String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    private var engineTab: some View {
        Form {
            Section("Speech-to-text") {
                Picker("Transcribe with", selection: $sttSource) {
                    Text("Apple (on-device)").tag(STTSource.apple)
                    Text("Remote whisper.cpp").tag(STTSource.remote)
                }
                if sttSource == .apple {
                    accentPicker
                    Text("Runs on-device with no setup. Audio never leaves your Mac. Pick the English closest to how you speak — a mismatch mishears words.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("https://host/inference", text: $whisperEndpoint)
                    Text("A whisper.cpp server's /inference endpoint. Audio is uploaded to it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Local rewrite engine (llama-server)") {
                Text("Only used when Cleanup runs in Local mode. See SETUP.md to build llama.cpp and fetch a model.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Binary") {
                    TextField("llama-server path", text: $llamaBinaryPath).lineLimit(1)
                }
                LabeledContent("Model") {
                    TextField("model .gguf path", text: $modelPath).lineLimit(1)
                }
                LabeledContent("Draft model") {
                    TextField("draft .gguf path (optional)", text: $draftModelPath).lineLimit(1)
                }
            }

            Text("Changes take effect after you restart TypeWiser.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onChange(of: sttSource) { _, new in model.settings.sttSource = new }
        .onChange(of: sttLocale) { _, new in model.settings.sttLocale = new }
        .onChange(of: whisperEndpoint) { _, new in model.settings.whisperEndpoint = new }
        .onChange(of: llamaBinaryPath) { _, new in model.settings.llamaBinaryPath = new }
        .onChange(of: modelPath) { _, new in model.settings.modelPath = new }
        .onChange(of: draftModelPath) { _, new in model.settings.draftModelPath = new }
    }

    private var cleanupTab: some View {
        Form {
            Toggle("Remove fillers (um, uh, hmm)", isOn: $options.removeFillers)
            Toggle("Fix grammar", isOn: $options.fixGrammar)
            Toggle("Remove repetition and false starts", isOn: $options.removeRepetition)
            Toggle("Resolve self-corrections", isOn: $options.resolveSelfCorrections)
            Text("\"Let's meet at 2… actually 3\" becomes \"Let's meet at 3.\"")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Use surrounding text to spell names", isOn: $options.contextAwareSpelling)
            Toggle("Format long dictations", isOn: $options.autoFormat)
            Text("Restores lists and email structure in longer dictations, using only words you said.")
                .font(.caption).foregroundStyle(.secondary)

            Section("Sound") {
                Toggle("Play sounds", isOn: $soundsEnabled)
                Text("A short tone when text is pasted, and a ping when you let go of the hotkey before anything was captured.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Name dictionary") {
                NameDictionaryField(names: $names)
                Text("Proper nouns to always spell this way.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: options) { _, new in model.settings.options = new }
        .onChange(of: names) { _, new in model.settings.nameDictionary = new }
        .onChange(of: soundsEnabled) { _, new in model.settings.soundsEnabled = new }
    }

    private var cloudTab: some View {
        Form {
            Section {
                Picker("Provider", selection: $cloudProvider) {
                    Text("AWS Bedrock").tag(CloudProvider.bedrock)
                    Text("OpenAI").tag(CloudProvider.openai)
                    Text("Anthropic").tag(CloudProvider.anthropic)
                }
                Text("Used when the engine is set to Cloud. Keys are stored in your macOS Keychain — never in a file.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            switch cloudProvider {
            case .bedrock: bedrockFields
            case .openai: openAIFields
            case .anthropic: anthropicFields
            }

            Text(savedMessage).font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onChange(of: cloudProvider) { _, new in model.settings.cloudProvider = new; savedMessage = "" }
        .onChange(of: openAIModel) { _, new in model.settings.openAIModel = new }
        .onChange(of: anthropicModel) { _, new in model.settings.anthropicModel = new }
    }

    private var bedrockFields: some View {
        Section("AWS Bedrock") {
            TextField("AWS Access Key ID", text: $accessKey)
            SecureField("AWS Secret Access Key", text: $secretKey)
            Text("Region: ap-south-1 · Model: apac.amazon.nova-lite-v1:0")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Save to Keychain") {
                    let c = AWSCredentials(accessKeyID: accessKey.trimmingCharacters(in: .whitespaces),
                                           secretAccessKey: secretKey.trimmingCharacters(in: .whitespaces),
                                           region: "ap-south-1")
                    do { try credentials.save(c); accessKey = ""; secretKey = ""; savedMessage = "Saved." }
                    catch { savedMessage = "Failed: \(error)" }
                }
                .disabled(accessKey.isEmpty || secretKey.isEmpty)
                Button("Delete") {
                    do { try credentials.delete(); savedMessage = "Deleted." }
                    catch { savedMessage = "Failed: \(error)" }
                }
            }
        }
    }

    private var openAIFields: some View {
        Section("OpenAI") {
            SecureField("API Key (sk-…)", text: $openAIKeyField)
            TextField("Model", text: $openAIModel)
            Text("Chat Completions API. A small, fast model is best for cleanup.")
                .font(.caption).foregroundStyle(.secondary)
            keyButtons(field: $openAIKeyField, store: openAIStore)
        }
    }

    private var anthropicFields: some View {
        Section("Anthropic") {
            SecureField("API Key (sk-ant-…)", text: $anthropicKeyField)
            TextField("Model", text: $anthropicModel)
            Text("Messages API. Defaults to Claude Haiku 4.5 — fast and cheap for cleanup.")
                .font(.caption).foregroundStyle(.secondary)
            keyButtons(field: $anthropicKeyField, store: anthropicStore)
        }
    }

    private func keyButtons(field: Binding<String>, store: KeychainAPIKeyStore) -> some View {
        HStack {
            Button("Save to Keychain") {
                do { try store.save(field.wrappedValue.trimmingCharacters(in: .whitespaces)); field.wrappedValue = ""; savedMessage = "Saved." }
                catch { savedMessage = "Failed: \(error)" }
            }
            .disabled(field.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Delete") {
                do { try store.delete(); savedMessage = "Deleted." }
                catch { savedMessage = "Failed: \(error)" }
            }
        }
    }

    private var setupTab: some View { OnboardingView(model: model) }
}
