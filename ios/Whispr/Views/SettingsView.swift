import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Backend") {
                    TextField("ws://<laptop-ip>:8787/ws", text: $model.backendURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Reconnect") { model.connect() }
                }
                Section {
                    Picker("Listen with", selection: $model.micSource) {
                        ForEach(MicSource.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Microphone")
                } footer: {
                    Text("If your headphones can't hear the other person, switch to the iPhone mic. Whispers still play in your headphones.")
                }
                Section("Test") {
                    Button("Fake: \"Wait, you saw Laufey live?\"") {
                        model.sendTestLine("Wait, you saw Laufey live? Which show?")
                    }
                    Button("Fake: \"Who's your favourite artist?\"") {
                        model.sendTestLine("Who's your favourite artist right now?")
                    }
                }
                if let error = model.lastError {
                    Section("Last error") { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
