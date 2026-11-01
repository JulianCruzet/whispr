import SwiftUI

/// Mission screen. Read at a glance mid-conversation: the line to say is the one big
/// reading; everything else is quiet greys, with colour only for good or bad.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 16) {
            header
            lineCard
            if model.listening {
                CoverReading(risk: model.risk)
                calibration
            }
            transcript
            proof
            controls
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Theme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: .constant(model.showsFakeCallScreen)) { FakeCallView() }
        .overlay(alignment: .top) { panicCountdown }
        .overlay { CallIslandOverlay() }
        .onAppear { if model.connection == .disconnected { model.connect() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Whispr")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.text)
                LabelText(model.persona.label)
            }
            Spacer()
            ConnectionChip(connection: model.connection, listening: model.listening)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.surface))
                    .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
            }
            .accessibilityLabel("Settings")
        }
    }

    // MARK: The line to say

    private var lineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                LabelText("In your ear")
                Spacer()
                if model.speaking {
                    VoiceBars(animated: !reduceMotion)
                        .transition(.opacity)
                }
            }
            Group {
                if let whisper = model.currentWhisper {
                    Text(whisper)
                        .font(Theme.display)
                        .tracking(-0.9)
                        .lineSpacing(-2)
                        .foregroundStyle(Theme.text)
                        .id(whisper)
                        .transition(reduceMotion ? .opacity : Theme.rise)
                } else {
                    Text(model.listening ? "Listening. Your next line shows up here." : "Start listening when the conversation begins.")
                        .font(.system(size: 20, weight: .medium))
                        .tracking(-0.4)
                        .foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(CardBackground())
        .animation(Theme.appear, value: model.currentWhisper)
        .animation(Theme.appear, value: model.speaking)
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
            .buttonStyle(PillButtonStyle(kind: .secondary, height: 40))
        case let .failed(who):
            Button {
                model.calibrate(who)
            } label: {
                Label(who == .me ? "Didn't catch you. Try again" : "Didn't catch them. Try again",
                      systemImage: "arrow.clockwise")
            }
            .buttonStyle(PillButtonStyle(kind: .secondary, height: 40))
        case let .sampling(who):
            CalibrationPrompt(
                step: who == .me ? "1/2" : "2/2",
                text: who == .me ? "Say one sentence in your normal voice" : "Have them say one sentence"
            )
        case .needThem:
            HStack(spacing: 8) {
                Button {
                    model.calibrate(.them)
                } label: {
                    Label("Now their voice", systemImage: "person.wave.2")
                }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 40))
                Button("Skip") { model.skipCalibratingThem() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 40))
                    .frame(width: 84)
            }
        case .done:
            EmptyView()
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.lines) { line in
                        TranscriptRow(line: line)
                            .id(line.id)
                            .transition(reduceMotion ? .opacity : Theme.rise)
                    }
                    if !model.partial.isEmpty {
                        TranscriptRow.partial(model.partial).id("partial")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(Theme.appear, value: model.lines.count)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.lines.count) {
                withAnimation(reduceMotion ? nil : Theme.appear) { proxy.scrollTo(model.lines.last?.id, anchor: .bottom) }
            }
        }
    }

    // MARK: Proof

    @ViewBuilder private var proof: some View {
        if !model.tasks.isEmpty || model.lastPhoto != nil {
            HStack(alignment: .center, spacing: 12) {
                if let photo = model.lastPhoto {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 54, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel("Proof photo")
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let task = model.tasks.last {
                        Text(task.done ? (model.lastPhoto == nil ? "No photo this time" : "Photo found") : task.label)
                            .font(Theme.emphasis)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                    if model.lastPhotoSaved {
                        MetaText("saved to photos", color: Theme.up)
                    } else if model.tasks.last?.done == false {
                        MetaText("searching…")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(CardBackground())
            .transition(Theme.rise)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            if model.listening && !model.route.isEmpty {
                MetaText(model.route)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            HStack(spacing: 8) {
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
                .frame(width: 120)
                .disabled(model.panic != .idle)
            }
        }
    }

    @ViewBuilder private var panicCountdown: some View {
        if case let .countdown(secondsLeft) = model.panic {
            HStack {
                Text("\(model.panicCallerName) calls in")
                    .font(Theme.emphasis)
                MetaText("\(secondsLeft)s", color: Theme.text)
                Spacer()
                Button("Cancel") { model.cancelPanic() }
                    .font(Theme.emphasis)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(Capsule().fill(Theme.surface2))
            .overlay(Capsule().strokeBorder(Theme.lineStrong, lineWidth: 1))
            .padding(.horizontal, 16)
            .transition(Theme.rise)
        }
    }
}

// MARK: - Pieces

/// Live / connecting / offline. The dot pulses while listening.
private struct ConnectionChip: View {
    let connection: AppModel.Connection
    let listening: Bool

    var body: some View {
        HStack(spacing: 4) {
            PulsingDot(color: color, pulsing: connection == .connected && listening)
            Text(label)
                .font(Theme.label)
                .foregroundStyle(Theme.text2)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(height: 30)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch connection {
        case .connected: listening ? "Listening" : "Live"
        case .connecting: "Connecting"
        case .disconnected: "Offline"
        }
    }

    private var color: Color {
        switch connection {
        case .connected: Theme.up
        case .connecting: Theme.muted
        case .disconnected: Theme.down
        }
    }
}

/// How close the wearer is to being caught, as a reading: green while it holds, red when blown.
private struct CoverReading: View {
    let risk: Double

    var body: some View {
        HStack(spacing: 12) {
            LabelText("Cover")
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, geometry.size.width * min(max(risk, 0), 1)))
                }
            }
            .frame(height: 3)
            Text(verdict)
                .font(Theme.label)
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(tint))
            MetaText(String(format: "%.2f", min(max(risk, 0), 1)))
                .frame(width: 34, alignment: .trailing)
        }
        .animation(Theme.appear, value: risk)
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

    private var color: Color {
        switch risk {
        case ..<0.34: Theme.up
        case ..<0.67: Theme.text2
        default: Theme.down
        }
    }

    private var tint: Color {
        switch risk {
        case ..<0.34: Theme.upTint
        case ..<0.67: Theme.surface2
        default: Theme.downTint
        }
    }
}

/// The calibration step in progress.
private struct CalibrationPrompt: View {
    let step: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(Theme.text2)
            Text(text)
                .font(Theme.emphasis)
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            MetaText(step)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.lineStrong, lineWidth: 1))
    }
}

/// Bars while Roxy is talking, in the text grey.
private struct VoiceBars: View {
    let animated: Bool

    var body: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<5) { i in
                    Capsule()
                        .fill(Theme.text2)
                        .frame(width: 2.5, height: animated ? 5 + 11 * abs(sin(t * 7 + Double(i) * 0.9)) : 9)
                }
            }
            .frame(height: 16)
        }
        .accessibilityLabel("Speaking")
    }
}

/// One line of the conversation: time, who, what. Their lines in full white; the wearer's muted.
private struct TranscriptRow: View {
    let time: String
    let speaker: String
    let text: String
    let muted: Bool
    var italic = false

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(line: TranscriptLine) {
        time = Self.clock.string(from: line.at)
        switch line.speaker {
        case .me: speaker = "You"
        case .them: speaker = "Them"
        case .unknown: speaker = "—"
        }
        text = line.text
        muted = line.speaker == .me
    }

    private init(partial: String) {
        time = "··:··:··"
        speaker = ""
        text = partial
        muted = true
        italic = true
    }

    static func partial(_ text: String) -> TranscriptRow { TranscriptRow(partial: text) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            MetaText(time)
            LabelText(speaker, color: muted ? Theme.muted : Theme.text2)
                .frame(width: 34, alignment: .leading)
            Text(text)
                .font(Theme.body)
                .italic(italic)
                .foregroundStyle(muted ? Theme.text2 : Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(muted ? .clear : Theme.surface))
    }
}
