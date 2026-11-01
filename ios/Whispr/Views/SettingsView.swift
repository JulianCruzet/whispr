import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AuthStore.self) private var auth
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
                        Text("Who Whispr coaches you to be. Changing it starts a new scene.")
                    }
                    Section {
                        Button("Calibrate my voice · 15 s") {
                            model.calibrateForDemo(.me)
                            dismiss()
                        }
                        Button("Calibrate their voice · 15 s") {
                            model.calibrateForDemo(.them)
                            dismiss()
                        }
                        Button("Clear calibrated voices", role: .destructive) {
                            model.clearCalibration()
                        }
                        .disabled(model.calibratedVoices.isEmpty)
                    } header: {
                        Text("Voices for the demo")
                    } footer: {
                        Text("15 seconds of each of you talking normally, so Whispr knows exactly who is who. Do yours first; the main screen shows the bar filling as you talk. Clear them before new people calibrate.")
                    }
                    .disabled(model.connection != .connected)
                    Section {
                        Picker("Listen with", selection: $model.micSource) {
                            ForEach(MicSource.allCases) { Text($0.label).tag($0) }
                        }
                    } header: {
                        Text("Microphone")
                    } footer: {
                        Text("If your headphones don't pick up the other person, use the iPhone mic. Whispr still talks in your headphones.")
                    }
                    Section {
                        Picker("Play Whispr on", selection: $model.phoneOutput) {
                            ForEach(PhoneOutput.allCases) { Text($0.label).tag($0) }
                        }
                    } header: {
                        Text("Without headphones")
                    } footer: {
                        Text("Headphones always come first. On the iPhone speaker, the other person hears Whispr too, and the mic pauses while it talks.")
                    }
                    Section {
                        TextField("Caller name", text: $model.panicCallerName)
                        Picker("Rings after", selection: $model.panicDelaySeconds) {
                            Text("Right away").tag(0)
                            Text("5 seconds").tag(5)
                            Text("10 seconds").tag(10)
                        }
                        Toggle("Use the iOS call screen", isOn: $model.panicUsesCallKit)
                            .tint(Theme.up)
                    } header: {
                        Text("Panic button")
                    } footer: {
                        Text("Panic fakes an incoming call so you can walk away. Listening pauses until you hang up. The iOS call screen looks real on a locked phone, but shows as a banner while Whispr is open.")
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
                    if let email = auth.email {
                        Section("Account") {
                            Text(email)
                            Button("Sign out", role: .destructive) {
                                if model.listening { model.stopListening() }
                                auth.signOut()
                            }
                        }
                    }
                    if let error = model.lastError {
                        Section("Last error") {
                            Text(error).foregroundStyle(Theme.down)
                        }
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
            }
        }
        .tint(Theme.text)
        .preferredColorScheme(.dark)
    }
}
