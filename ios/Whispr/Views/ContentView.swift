import SwiftUI

/// Mission screen. Read at a glance mid-conversation: the line to say is the biggest thing on it.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 18) {
            header
            cueCard
            if model.listening {
                CoverMeter(risk: model.risk)
                calibrationBanner
            }
            transcript
            proof
            controls
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(PinstripeBackground())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: .constant(model.showsFakeCallScreen)) { FakeCallView() }
        .overlay(alignment: .top) { panicCountdown }
        .onAppear { if model.connection == .disconnected { model.connect() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Whispr")
                    .font(Theme.display(34, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.chalk)
                TicketText("Playing · \(model.persona.label)")
            }
            Spacer()
            ConnectionTag(connection: model.connection)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(Theme.brass)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Settings")
        }
    }

    // MARK: The lining: the line to say

    private var cueCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                WovenLabel(text: "In your ear")
                Spacer()
                if model.speaking {
                    VoiceBars(animated: !reduceMotion)
                        .transition(.opacity)
                }
            }
            Group {
                if let whisper = model.currentWhisper {
                    Text(whisper)
                        .font(Theme.display(29))
                        .foregroundStyle(Theme.chalk)
                        .id(whisper)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                } else {
                    Text(model.listening ? "Listening. Your next line shows up here." : "Start listening when the conversation begins.")
                        .font(Theme.displayItalic(22))
                        .foregroundStyle(Theme.chalk.opacity(0.55))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .background(LiningBackground())
        .animation(.easeOut(duration: 0.35), value: model.currentWhisper)
        .animation(.easeOut(duration: 0.2), value: model.speaking)
        .accessibilityElement(children: .combine)
    }

    // MARK: Calibration

    @ViewBuilder private var calibrationBanner: some View {
        switch model.calibration {
        case .none, .failed:
            Button {
                model.calibrate()
            } label: {
                Label(model.calibration == .failed ? "Didn't catch that. Try again" : "Calibrate my voice",
                      systemImage: "person.wave.2")
            }
            .buttonStyle(BrassButtonStyle(filled: false))
        case .listening:
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                Text("Say one sentence in your normal voice")
            }
            .font(.subheadline)
            .foregroundStyle(Theme.brass)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Capsule().fill(Theme.brass.opacity(0.12)))
        case .done:
            EmptyView()
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.lines) { line in
                        TranscriptRow(line: line).id(line.id)
                    }
                    if !model.partial.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            TicketText("···").frame(width: 42, alignment: .leading)
                            Text(model.partial)
                                .italic()
                                .foregroundStyle(Theme.smoke)
                        }
                        .id("partial")
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
            HStack(alignment: .bottom, spacing: 14) {
                if let photo = model.lastPhoto {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.brass.opacity(0.6), lineWidth: 1))
                        .accessibilityLabel("Proof photo")
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let task = model.tasks.last {
                        HStack(spacing: 6) {
                            Image(systemName: task.done ? "checkmark" : "hourglass")
                                .foregroundStyle(Theme.brass)
                            Text(task.done ? "Photo found" : task.label)
                                .foregroundStyle(Theme.chalk)
                                .lineLimit(1)
                        }
                        .font(.subheadline)
                    }
                    if model.lastPhotoSaved {
                        TicketText("Saved to Photos", color: Theme.brass)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            if model.listening && !model.route.isEmpty {
                TicketText(model.route)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            HStack(spacing: 12) {
                Button(model.listening ? "Stop" : "Start listening") { model.toggleListening() }
                    .buttonStyle(BrassButtonStyle(filled: !model.listening))
                    .disabled(model.connection != .connected)
                // Works offline: the fake call needs no backend.
                Button {
                    model.triggerPanic()
                } label: {
                    Label("Panic", systemImage: "phone.badge.waveform.fill")
                }
                .buttonStyle(BrassButtonStyle(fill: Theme.alarm))
                .frame(width: 132)
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
            .foregroundStyle(Theme.chalk)
            .padding(16)
            .background(Theme.alarm, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Pieces

/// Connection state as a ticket: brass dot when live.
private struct ConnectionTag: View {
    let connection: AppModel.Connection

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            TicketText(label, color: color)
        }
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
        case .connected: Theme.brass
        case .connecting: Theme.smoke
        case .disconnected: Theme.alarm
        }
    }
}

/// How close the wearer is to being caught, from the brain's risk score.
private struct CoverMeter: View {
    let risk: Double

    var body: some View {
        HStack(spacing: 10) {
            TicketText("Cover")
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.pinstripe)
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.brass, Theme.alarm], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geometry.size.width * min(max(risk, 0), 1)))
                }
            }
            .frame(height: 4)
            TicketText(verdict, color: risk >= 0.67 ? Theme.alarm : Theme.smoke)
                .frame(width: 48, alignment: .trailing)
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

/// Brass sound bars while Roxy is talking.
private struct VoiceBars: View {
    let animated: Bool

    var body: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<5) { i in
                    Capsule()
                        .fill(Theme.brass)
                        .frame(width: 3, height: animated ? 6 + 12 * abs(sin(t * 7 + Double(i) * 0.9)) : 10)
                }
            }
            .frame(height: 18)
        }
        .accessibilityLabel("Speaking")
    }
}

/// One finished line. The other person's lines stand out; the wearer's are muted.
private struct TranscriptRow: View {
    let line: TranscriptLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TicketText(label, color: line.speaker == .them ? Theme.brass : Theme.smoke)
                .frame(width: 42, alignment: .leading)
            Text(line.text)
                .foregroundStyle(line.speaker == .me ? Theme.smoke : Theme.chalk)
        }
    }

    private var label: String {
        switch line.speaker {
        case .me: "You"
        case .them: "Them"
        case .unknown: "—"
        }
    }
}
