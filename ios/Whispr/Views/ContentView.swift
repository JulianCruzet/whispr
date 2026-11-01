import SwiftUI

/// Mission screen. Person C owns the look; keep it readable from across a table.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                whisperCard
                transcript
                tasks
                listenButton
            }
            .padding()
            .navigationTitle("Whispr")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { connectionDot }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear { if model.connection == .disconnected { model.connect() } }
        }
    }

    private var whisperCard: some View {
        Text(model.currentWhisper ?? "Waiting for your cue…")
            .font(.title2.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding()
            .background(.indigo.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.lines) { line in
                    Text("\(line.speaker.rawValue): \(line.text)")
                }
                if !model.partial.isEmpty {
                    Text(model.partial).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var tasks: some View {
        ForEach(model.tasks) { task in
            HStack {
                Image(systemName: task.done ? "checkmark.circle.fill" : "hourglass")
                Text(task.label).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let photo = model.lastPhoto {
            Image(uiImage: photo)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var listenButton: some View {
        Button(model.listening ? "Stop" : "Start listening") { model.toggleListening() }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.connection != .connected)
    }

    private var connectionDot: some View {
        Circle()
            .fill(model.connection == .connected ? .green : model.connection == .connecting ? .yellow : .red)
            .frame(width: 10, height: 10)
    }
}
