import SwiftUI
import TypeWiserCore

/// Three tabs: rewrite-rule toggles + name dictionary, AWS credentials
/// (Keychain-backed), and onboarding checks that verify (not merely
/// instruct) the machine is actually set up correctly.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var options = RewriteOptions.default
    @State private var names = ""
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var savedMessage = ""

    private let credentials = KeychainCredentialStore()

    var body: some View {
        TabView {
            cleanupTab.tabItem { Label("Cleanup", systemImage: "wand.and.sparkles") }
            cloudTab.tabItem { Label("Cloud", systemImage: "cloud") }
            setupTab.tabItem { Label("Setup", systemImage: "checkmark.shield") }
        }
        .frame(width: 460, height: 340)
        .onAppear {
            options = model.settings.options
            names = model.settings.nameDictionary.joined(separator: ", ")
        }
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

            Section("Name dictionary") {
                TextField("Comma-separated", text: $names, axis: .vertical)
                    .lineLimit(2...4)
                Text("Proper nouns to always spell this way.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: options) { _, new in model.settings.options = new }
        .onChange(of: names) { _, new in
            model.settings.nameDictionary = new
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    private var cloudTab: some View {
        Form {
            Text("Used when the engine is set to Cloud. Stored in your macOS Keychain — never in a file.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("AWS Access Key ID", text: $accessKey)
            SecureField("AWS Secret Access Key", text: $secretKey)
            Text("Region: ap-south-1 · Model: apac.amazon.nova-lite-v1:0")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Save to Keychain") {
                    let c = AWSCredentials(accessKeyID: accessKey.trimmingCharacters(in: .whitespaces),
                                           secretAccessKey: secretKey.trimmingCharacters(in: .whitespaces),
                                           region: "ap-south-1")
                    do {
                        try credentials.save(c)
                        accessKey = ""; secretKey = ""
                        savedMessage = "Saved."
                    } catch {
                        savedMessage = "Failed: \(error)"
                    }
                }
                .disabled(accessKey.isEmpty || secretKey.isEmpty)
                Button("Delete") {
                    do {
                        try credentials.delete()
                        savedMessage = "Deleted."
                    } catch {
                        savedMessage = "Failed: \(error)"
                    }
                }
                Text(savedMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var setupTab: some View { OnboardingView(model: model) }
}
