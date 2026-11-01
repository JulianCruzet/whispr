import SwiftUI

/// Mission screen. Person C owns the look; keep it readable from across a table.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                whisperCard
                calibrationBanner
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
                    TranscriptRow(line: line)
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

    /// Asks the wearer to say one sentence so the backend learns their voice level.
    @ViewBuilder private var calibrationBanner: some View {
        if model.listening {
            switch model.calibration {
            case .none, .failed:
                Button {
                    model.calibrate()
                } label: {
                    Label(model.calibration == .failed ? "Didn't catch that, try again" : "Calibrate my voice",
                          systemImage: "person.wave.2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            case .listening:
                Label("Say any sentence in your normal voice…", systemImage: "waveform")
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(.yellow.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
            case .done:
                EmptyView()
            }
        }
    }

    private var listenButton: some View {
        VStack(spacing: 6) {
            if model.listening && !model.route.isEmpty {
                Text(model.route)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(model.listening ? "Stop" : "Start listening") { model.toggleListening() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.connection != .connected)
        }
    }

    private var connectionDot: some View {
        Circle()
            .fill(model.connection == .connected ? .green : model.connection == .connecting ? .yellow : .red)
            .frame(width: 10, height: 10)
    }
}

/// One finished line. The other person's lines stand out; the wearer's are muted.
private struct TranscriptRow: View {
    let line: TranscriptLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 44, alignment: .leading)
            Text(line.text)
                .foregroundStyle(line.speaker == .me ? .secondary : .primary)
        }
    }

    private var label: String {
        switch line.speaker {
        case .me: "YOU"
        case .them: "THEM"
        case .unknown: "?"
        }
    }

    private var color: Color {
        switch line.speaker {
        case .me: .gray
        case .them: .orange
        case .unknown: .secondary
        }
    }
}
