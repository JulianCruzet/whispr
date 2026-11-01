import SwiftUI

/// Voice calibration before a demo, on its own page. Nothing said here goes into the
/// conversation, and Whispr never answers it.
struct CalibrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Listening is switched back off on the way out if this page turned it on.
    @State private var wasListening = true

    private var sampling: Bool {
        if case .sampling = model.calibration { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Each of you talks normally for 15 seconds, so Whispr knows exactly who is who. Nothing said here goes into the conversation, and Whispr stays quiet.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                CalibrationStep(who: .me, title: "You", hint: "Talk normally until the bar fills", step: "1/2")
                CalibrationStep(who: .them, title: "Them", hint: "Get them talking until the bar fills", step: "2/2")
                Button("Clear calibrated voices") { model.clearCalibration() }
                    .buttonStyle(PillButtonStyle(kind: .alarm, height: 40))
                    .disabled(model.calibratedVoices.isEmpty || sampling)
                if model.connection != .connected {
                    MetaText("offline: connect to the backend to calibrate", color: Theme.down)
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Calibrate voices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { wasListening = model.listening }
        .onDisappear {
            model.cancelCalibration()
            if !wasListening && model.listening { model.stopListening() }
        }
    }
}

/// One person's step: start it, watch the bar fill, then a green tick.
private struct CalibrationStep: View {
    @Environment(AppModel.self) private var model
    let who: Speaker
    let title: String
    let hint: String
    let step: String

    private var done: Bool { model.calibratedVoices.contains(who) }

    private var busy: Bool {
        if case .sampling = model.calibration { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(Theme.emphasis)
                    .foregroundStyle(Theme.text)
                Spacer()
                if done {
                    Label("Calibrated", systemImage: "checkmark.circle.fill")
                        .font(Theme.label)
                        .foregroundStyle(Theme.up)
                }
            }
            switch model.calibration {
            case let .sampling(current, heard, target) where current == who:
                CalibrationPrompt(step: step, text: hint, heard: heard, target: target)
            case let .failed(current, soundedLikeYou) where current == who:
                Text(soundedLikeYou ? "That sounded like you. Get them talking, then try again." : "Didn't catch enough. Try again.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.down)
                startButton(label: "Try again · 15 s")
            default:
                startButton(label: done ? "Redo · 15 s" : "Start · 15 s")
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(done ? Theme.upTint : Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(done ? Theme.up.opacity(0.45) : Theme.line, lineWidth: 1))
        )
        .animation(Theme.appear, value: model.calibration)
    }

    private func startButton(label: String) -> some View {
        Button(label) { model.calibrateForDemo(who) }
            .buttonStyle(PillButtonStyle(kind: done ? .secondary : .primary, height: 40))
            .disabled(busy || model.connection != .connected)
    }
}
