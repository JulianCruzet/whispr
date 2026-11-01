import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Group {
                    Section {
                        Picker("Playing", selection: $model.persona) {
                            ForEach(Persona.allCases) { Text($0.label).tag($0) }
                        }
                    } header: {
                        Text("Persona")
                    } footer: {
                        Text("Who Roxy coaches you to be. Changing it starts a new scene.")
                    }
                    Section {
                        Picker("Listen with", selection: $model.micSource) {
                            ForEach(MicSource.allCases) { Text($0.label).tag($0) }
                        }
                    } header: {
                        Text("Microphone")
                    } footer: {
                        Text("If your headphones don't pick up the other person, use the iPhone mic. Roxy still talks in your headphones.")
                    }
                    Section {
                        TextField("Caller name", text: $model.panicCallerName)
                        Picker("Rings after", selection: $model.panicDelaySeconds) {
                            Text("Right away").tag(0)
                            Text("5 seconds").tag(5)
                            Text("10 seconds").tag(10)
                        }
                        Toggle("Ring when Whispr is closed", isOn: $model.panicUsesCallKit)
                    } header: {
                        Text("Panic button")
                    } footer: {
                        Text("Panic fakes an incoming call so you can walk away. Listening pauses until you hang up. With Whispr open, the call stays in a small pill after you answer. On a locked phone or in another app, iOS shows its own call screen, labelled Whispr Audio.")
                    }
                    Section {
                        Button("They say: \"Wait, you saw Laufey live?\"") {
                            model.sendTestLine("Wait, you saw Laufey live? Which show?")
                        }
                        Button("They say: \"Who's your favourite artist?\"") {
                            model.sendTestLine("Who's your favourite artist right now?")
                        }
                    } header: {
                        Text("Practice")
                    } footer: {
                        Text("Sends their line without anyone speaking. Use it to check the voice, or if the mic struggles during a demo.")
                    }
                    Section {
                        TextField("wss://<host>/ws", text: $model.backendURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button("Reconnect") { model.connect() }
                    } header: {
                        Text("Server")
                    }
                    if let error = model.lastError {
                        Section("Last error") {
                            Text(error).foregroundStyle(Theme.brick)
                        }
                    }
                }
                .listRowBackground(Color.white)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.linen.ignoresSafeArea())
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
            }
        }
        .tint(Theme.graphite)
        .preferredColorScheme(.light)
    }
}
