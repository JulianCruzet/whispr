import SwiftUI

/// Mission screen. Read at a glance mid-conversation: the line to say is the biggest,
/// darkest thing on it; everything else stays quiet.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 20) {
            header
            lineCard
            if model.listening {
                CoverMeter(risk: model.risk)
                calibration
            }
            transcript
            proof
            controls
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Theme.paper.ignoresSafeArea())
        .preferredColorScheme(.light)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: .constant(model.showsFakeCallScreen)) { FakeCallView() }
        .overlay(alignment: .top) { panicCountdown }
        .onAppear { if model.connection == .disconnected { model.connect() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Whispr")
                    .font(Theme.serif(.largeTitle))
                    .foregroundStyle(Theme.graphite)
                LabelText("Playing \(model.persona.label)")
            }
            Spacer()
            ConnectionPill(connection: model.connection)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.graphite)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.linen))
            }
            .accessibilityLabel("Settings")
        }
    }

    // MARK: The line to say

    private var lineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                LabelText("In your ear", color: Theme.cream.opacity(0.65))
                Spacer()
                if model.speaking {
                    VoiceBars(animated: !reduceMotion)
                        .transition(.opacity)
                }
            }
            Group {
                if let whisper = model.currentWhisper {
                    Text(whisper)
                        .font(Theme.serif(.title))
                        .foregroundStyle(Theme.cream)
                        .id(whisper)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                } else {
                    Text(model.listening ? "Listening. Your next line shows up here." : "Start listening when the conversation begins.")
                        .font(Theme.serif(.title2))
                        .foregroundStyle(Theme.cream.opacity(0.55))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.bronze))
        .animation(.easeOut(duration: 0.35), value: model.currentWhisper)
        .animation(.easeOut(duration: 0.2), value: model.speaking)
        .accessibilityElement(children: .combine)
    }

    // MARK: Calibration

    @ViewBuilder private var calibration: some View {
        switch model.calibration {
        case .none:
            Button {
                model.calibrate(.me)
            } label: {
                Label("Calibrate voices", systemImage: "person.2.wave.2")
            }
            .buttonStyle(PillButtonStyle(kind: .quiet))
        case let .failed(who):
            Button {
                model.calibrate(who)
            } label: {
                Label(who == .me ? "Didn't catch you. Try again" : "Didn't catch them. Try again",
                      systemImage: "arrow.clockwise")
            }
            .buttonStyle(PillButtonStyle(kind: .quiet))
        case let .sampling(who):
            CalibrationPrompt(
                step: who == .me ? "1 of 2" : "2 of 2",
                text: who == .me ? "Say one sentence in your normal voice" : "Have them say one sentence"
            )
        case .needThem:
            HStack(spacing: 10) {
                Button {
                    model.calibrate(.them)
                } label: {
                    Label("Now their voice", systemImage: "person.wave.2")
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                Button("Skip") { model.skipCalibratingThem() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .frame(width: 92)
            }
        case .done:
            EmptyView()
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.lines) { line in
                        TranscriptRow(line: line).id(line.id)
                    }
                    if !model.partial.isEmpty {
                        TranscriptRow.partial(model.partial).id("partial")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.lines.count) {
                withAnimation(reduceMotion ? nil : .easeOut) { proxy.scrollTo(model.lines.last?.id, anchor: .bottom) }
            }
        }
    }

    // MARK: Proof

    @ViewBuilder private var proof: some View {
        if !model.tasks.isEmpty || model.lastPhoto != nil {
            HStack(alignment: .center, spacing: 14) {
                if let photo = model.lastPhoto {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Proof photo")
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let task = model.tasks.last {
                        Text(task.done ? (model.lastPhoto == nil ? "No photo this time" : "Photo found") : task.label)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Theme.graphite)
                            .lineLimit(1)
                    }
                    if model.lastPhotoSaved {
                        Label("Saved to Photos", systemImage: "checkmark")
                            .font(Theme.label)
                            .foregroundStyle(Theme.moss)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stone, lineWidth: 1))
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            if model.listening && !model.route.isEmpty {
                LabelText(model.route)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            HStack(spacing: 10) {
                Button(model.listening ? "Stop" : "Start listening") { model.toggleListening() }
                    .buttonStyle(PillButtonStyle(kind: model.listening ? .secondary : .primary))
                    .disabled(model.connection != .connected)
                // Works offline: the fake call needs no backend.
                Button {
                    model.triggerPanic()
                } label: {
                    Label("Panic", systemImage: "phone.fill")
                }
                .buttonStyle(PillButtonStyle(kind: .alarm))
                .frame(width: 128)
                .disabled(model.panic != .idle)
            }
        }
    }

    @ViewBuilder private var panicCountdown: some View {
        if case let .countdown(secondsLeft) = model.panic {
            HStack {
                Text("\(model.panicCallerName) calls in \(secondsLeft)")
                    .font(.headline.monospacedDigit())
                Spacer()
                Button("Cancel") { model.cancelPanic() }
                    .font(.headline)
            }
            .foregroundStyle(Theme.paper)
            .padding(16)
            .background(Capsule().fill(Theme.charcoal))
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Pieces

private struct ConnectionPill: View {
    let connection: AppModel.Connection

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(Theme.label)
                .foregroundStyle(Theme.graphite)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.linen))
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch connection {
        case .connected: "Live"
        case .connecting: "Connecting"
        case .disconnected: "Offline"
        }
    }

    private var color: Color {
        switch connection {
        case .connected: Theme.moss
        case .connecting: Theme.pebble
        case .disconnected: Theme.brick
        }
    }
}

/// How close the wearer is to being caught, from the brain's risk score.
private struct CoverMeter: View {
    let risk: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LabelText("Cover")
                Spacer()
                Text(verdict)
                    .font(Theme.label)
                    .foregroundStyle(risk >= 0.67 ? Theme.brick : Theme.graphite)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.stone)
                    Capsule()
                        .fill(risk >= 0.67 ? Theme.brick : Theme.graphite)
                        .frame(width: max(4, geometry.size.width * min(max(risk, 0), 1)))
                }
            }
            .frame(height: 3)
        }
        .animation(.easeOut(duration: 0.4), value: risk)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cover \(verdict)")
    }

    private var verdict: String {
        switch risk {
        case ..<0.34: "Solid"
        case ..<0.67: "Shaky"
        default: "Blown"
        }
    }
}

/// Cream sound bars on the bronze panel while Roxy is talking.
private struct VoiceBars: View {
    let animated: Bool

    var body: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<5) { i in
                    Capsule()
                        .fill(Theme.cream.opacity(0.85))
                        .frame(width: 3, height: animated ? 6 + 12 * abs(sin(t * 7 + Double(i) * 0.9)) : 10)
                }
            }
            .frame(height: 18)
        }
        .accessibilityLabel("Speaking")
    }
}

/// One line of the conversation, separated by hairlines. Their lines read at full weight;
/// the wearer's are muted.
private struct TranscriptRow: View {
    let speaker: String
    let text: String
    let muted: Bool
    var italic = false

    init(line: TranscriptLine) {
        switch line.speaker {
        case .me: speaker = "You"
        case .them: speaker = "Them"
        case .unknown: speaker = "—"
        }
        text = line.text
        muted = line.speaker == .me
    }

    private init(partial: String) {
        speaker = ""
        text = partial
        muted = true
        italic = true
    }

    static func partial(_ text: String) -> TranscriptRow { TranscriptRow(partial: text) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            LabelText(speaker)
                .frame(width: 40, alignment: .leading)
            Text(text)
                .italic(italic)
                .foregroundStyle(muted ? Theme.pebble : Theme.graphite)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stone).frame(height: 0.5) }
    }
}

/// The calibration step in progress: which sentence we're waiting for.
private struct CalibrationPrompt: View {
    let step: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
            Text(text)
            Spacer(minLength: 0)
            LabelText(step)
        }
        .font(.body.weight(.medium))
        .foregroundStyle(Theme.graphite)
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .background(Capsule().strokeBorder(Theme.stone, lineWidth: 1))
    }
}

