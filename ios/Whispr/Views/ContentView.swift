import SwiftUI

/// Mission screen. Read at a glance mid-conversation: the line to say is the one big
/// reading; everything else is quiet greys, with colour only for good or bad.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSettings = false
    @State private var showCalibration = false

    var body: some View {
        VStack(spacing: 16) {
            header
            lineCard
            if model.listening {
                CoverReading(risk: model.risk)
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
            Button {
                showCalibration = true
            } label: {
                VoicesChip(voices: model.calibratedVoices)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showCalibration) {
                NavigationStack { CalibrationView() }
            }
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
        .animation(Theme.appear, value: model.calibratedVoices)
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
        if let task = model.tasks.last {
            Group {
                if task.done, let photo = model.lastPhoto {
                    Button { model.openPhoto() } label: {
                        FoundPhotoCard(photo: photo, notice: model.photoNotice, saved: model.lastPhotoSaved)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(model.lastPhotoSaved ? "Opens Photos" : "Shows the photo")
                } else {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(!task.done ? task.label : task.imageUrl == nil ? "No photo this time" : "Getting the photo…")
                                .font(Theme.emphasis)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            if !task.done { MetaText("searching…") }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(CardBackground())
                }
            }
            .transition(Theme.rise)
            .animation(Theme.appear, value: model.lastPhoto)
            // A buzz too, in case the alert in the ear was missed.
            .sensoryFeedback(.success, trigger: model.lastPhotoSaved) { _, saved in saved }
            .fullScreenCover(isPresented: Binding(get: { model.showsPhotoFullScreen },
                                                  set: { model.showsPhotoFullScreen = $0 })) {
                if let photo = model.lastPhoto {
                    PhotoViewer(image: photo) { model.showsPhotoFullScreen = false }
                }
            }
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

/// Whose voices are calibrated: green when both are, so who said what is decided by voice.
/// With none, it's the way into calibration.
private struct VoicesChip: View {
    let voices: Set<Speaker>

    private var both: Bool { voices.contains(.me) && voices.contains(.them) }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: both ? "person.2.wave.2.fill" : voices.isEmpty ? "person.2.wave.2" : "person.wave.2.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(both ? "Voices" : voices.isEmpty ? "Calibrate" : voices.contains(.me) ? "You" : "Them")
                .font(Theme.label)
        }
        .foregroundStyle(both ? Theme.up : Theme.text2)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule().fill(both ? Theme.upTint : Theme.surface))
        .overlay(Capsule().strokeBorder(both ? Theme.up.opacity(0.45) : Theme.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(both ? "Both voices calibrated" : voices.isEmpty ? "Calibrate voices" : voices.contains(.me) ? "Your voice calibrated" : "Their voice calibrated")
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

/// The proof photo, landed: the one green card on screen, so it's seen at a glance.
/// Tapping it opens Photos, where the photo is the newest.
private struct FoundPhotoCard: View {
    let photo: UIImage
    let notice: String?
    let saved: Bool

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: 60, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.up.opacity(0.4), lineWidth: 1))
                .accessibilityLabel("Proof photo")
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    PulsingDot(color: Theme.up, pulsing: true)
                    Text("Photo found")
                        .font(Theme.emphasis)
                        .foregroundStyle(Theme.up)
                }
                if let notice {
                    Text(notice)
                        .font(Theme.body)
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                MetaText(saved ? "in your camera roll · tap to open" : "tap to show", color: Theme.up.opacity(0.85))
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.up)
        }
        .padding(12)
        .background(
            shape
                .fill(Theme.surface)
                .overlay(shape.fill(LinearGradient(colors: [Theme.up.opacity(0.24), Theme.up.opacity(0.03)],
                                                   startPoint: .leading, endPoint: .trailing)))
                .overlay(shape.strokeBorder(Theme.up.opacity(0.5), lineWidth: 1))
                .shadow(color: Theme.up.opacity(0.22), radius: 16)
        )
        .contentShape(shape)
    }
}

/// The proof photo full screen, for when it isn't in the camera roll or Photos won't open.
private struct PhotoViewer: View {
    let image: UIImage
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.surface))
            }
            .padding(16)
            .accessibilityLabel("Close")
        }
        .onTapGesture(perform: close)
    }
}

/// The calibration step in progress, with how much of the person's speech it has heard.
struct CalibrationPrompt: View {
    let step: String
    let text: String
    let heard: Double
    /// Nil until the backend reports after the first line.
    let target: Double?

    private var progress: Double {
        guard let target, target > 0 else { return 0 }
        return min(heard / target, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .foregroundStyle(Theme.text2)
                Text(text)
                    .font(Theme.emphasis)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Spacer(minLength: 0)
                MetaText(step)
            }
            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line)
                        Capsule().fill(Theme.text).frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 3)
                .animation(Theme.appear, value: progress)
                MetaText(target.map { String(format: "%.1f / %.1f s", min(heard, $0), $0) } ?? "listening")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.lineStrong, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityValue(target == nil ? "Listening" : "\(Int(progress * 100)) percent")
    }
}

/// Bars while Whispr is talking, in the text grey.
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
