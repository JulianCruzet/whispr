import AudioToolbox
import AVFoundation
import Foundation
import Observation
import UIKit

struct TranscriptLine: Identifiable {
    let id: String
    var text: String
    var speaker: Speaker
    /// When the line was finished, shown as a mono timestamp.
    var at = Date()
}

struct ProofTask: Identifiable {
    let id: String
    var label: String
    var done = false
    var imageUrl: URL?
}

/// Who the wearer is playing. Raw values match backend/app/personas.py.
enum Persona: String, CaseIterable, Identifiable {
    case fan
    case interview
    case firstDate = "first_date"
    case carSalesman = "car_salesman"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fan: "Superfan"
        case .interview: "Job interview"
        case .firstDate: "First date"
        case .carSalesman: "Car salesman"
        }
    }
}

/// App state for the UI. Audio (ears & voice) plugs in via `startListening` / `stopListening`.
@MainActor
@Observable
final class AppModel {
    enum Connection { case disconnected, connecting, connected }

    var connection: Connection = .disconnected
    var listening = false
    var lines: [TranscriptLine] = []
    var partial = ""
    var currentWhisper: String?
    /// Roxy's voice is streaming into the wearer's ear right now.
    var speaking = false
    var risk: Double = 0
    var tasks: [ProofTask] = []
    var lastError: String?
    /// Current audio route, e.g. "Mic: WH-1000XM5 · Voice: WH-1000XM5".
    var route = ""

    /// Calibration takes a voice sample of the wearer, then of the other person, so the
    /// backend can tell them apart by voice. The second step can be skipped.
    enum Calibration: Equatable {
        case none
        /// Waiting for a sentence from this person.
        case sampling(Speaker)
        /// The wearer's sample is in; ask for the other person's.
        case needThem
        /// This person's sentence was too short or quiet to use.
        case failed(Speaker)
        /// Both samples, or the wearer's only (then the backend falls back to loudness).
        case done(bothVoices: Bool)
    }
    var calibration: Calibration = .none

    var lastPhoto: UIImage?
    /// Whether lastPhoto made it into the camera roll.
    var lastPhotoSaved = false

    // MARK: Panic button state

    enum Panic: Equatable {
        case idle
        /// Counting down before the call rings (time to pocket or lock the phone).
        case countdown(secondsLeft: Int)
        case ringing
        case inCall(since: Date)
    }
    var panic: Panic = .idle

    var panicCallerName: String {
        didSet { UserDefaults.standard.set(panicCallerName, forKey: "panicCallerName") }
    }
    /// Ring through CallKit if Whispr isn't on screen when the call comes in. While it's open
    /// the app always draws the call itself, because iOS's screen takes over once you answer.
    var panicUsesCallKit: Bool {
        didSet { UserDefaults.standard.set(panicUsesCallKit, forKey: "panicUsesCallKit") }
    }
    var panicDelaySeconds: Int {
        didSet { UserDefaults.standard.set(panicDelaySeconds, forKey: "panicDelaySeconds") }
    }

    /// This call is on CallKit, so iOS draws the banner and the pill.
    private(set) var panicOnCallKit = false
    /// The full-screen call is open rather than the banner or pill.
    private var panicCallScreenOpen = false

    var showsFakeCallScreen: Bool {
        switch panic {
        case .ringing, .inCall: panicCallScreenOpen
        case .idle, .countdown: false
        }
    }

    /// The incoming-call banner is up.
    var showsCallBanner: Bool {
        panic == .ringing && !panicCallScreenOpen && !panicOnCallKit
    }

    /// When the call pill should show, the time the call was answered.
    var callPillSince: Date? {
        guard case let .inCall(since) = panic, !panicCallScreenOpen, !panicOnCallKit else { return nil }
        return since
    }

    var backendURL: String {
        didSet { UserDefaults.standard.set(backendURL, forKey: "backendURL") }
    }

    var micSource: MicSource {
        didSet {
            UserDefaults.standard.set(micSource.rawValue, forKey: "micSource")
            if listening { Task { await restartListening() } }
        }
    }

    var persona: Persona {
        didSet {
            UserDefaults.standard.set(persona.rawValue, forKey: "persona")
            sendPersona()
        }
    }

    private let client = BackendClient()
    private let audio = AudioPipeline()
    private let callKit = FakeCallKit()
    private let ringtone = Ringtone()
    private var panicTask: Task<Void, Never>?
    private var vibrationTask: Task<Void, Never>?
    private var resumeListeningAfterPanic = false

    init() {
        backendURL = UserDefaults.standard.string(forKey: "backendURL")
            ?? Bundle.main.object(forInfoDictionaryKey: "WhisprBackendURL") as? String
            ?? "ws://localhost:8787/ws"
        micSource = MicSource(rawValue: UserDefaults.standard.string(forKey: "micSource") ?? "") ?? .airpods
        persona = Persona(rawValue: UserDefaults.standard.string(forKey: "persona") ?? "") ?? .fan
        panicCallerName = UserDefaults.standard.string(forKey: "panicCallerName") ?? "Mom"
        panicUsesCallKit = UserDefaults.standard.bool(forKey: "panicUsesCallKit")
        panicDelaySeconds = UserDefaults.standard.object(forKey: "panicDelaySeconds") as? Int ?? 0

        callKit.onAnswered = { [weak self] in Task { @MainActor in self?.answerFakeCall() } }
        callKit.onEnded = { [weak self] in Task { @MainActor in self?.endFakeCall() } }

        let client = client
        audio.onMicChunk = { chunk in client.send(audio: chunk) }
        let audio = audio
        client.onAudio = { data in audio.play(data) }
        client.onEvent = { [weak self] event in Task { @MainActor in self?.handle(event) } }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.route = AudioPipeline.routeDescription() }
        }
        client.onDisconnect = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                // Keep the mic running: chunks are dropped while offline and flow again on reconnect.
                self.connection = .disconnected
                if let error { self.lastError = error.localizedDescription }
                self.scheduleReconnect()
            }
        }
        startKeepalive()
    }

    func connect() {
        guard let url = URL(string: backendURL) else {
            lastError = "Bad backend URL"
            return
        }
        connection = .connecting
        client.connect(to: url)
    }

    // MARK: Staying connected

    private var reconnectAttempt = 0
    private var reconnectPending = false

    /// Retries with backoff (0.5 s, 1 s, 2 s, then every 4 s) until the backend answers.
    private func scheduleReconnect() {
        guard !reconnectPending else { return }
        reconnectPending = true
        let delay = min(4.0, 0.5 * pow(2.0, Double(reconnectAttempt)))
        reconnectAttempt += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.reconnectPending = false
            if self.connection == .disconnected { self.connect() }
        }
    }

    /// Tunnels and hosts drop idle WebSockets; a ping every 20 s keeps it open between turns.
    private func startKeepalive() {
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                if self.connection == .connected { self.client.send(json: ["type": "ping"]) }
            }
        }
    }

    func toggleListening() {
        if listening {
            stopListening()
        } else {
            Task { await startListening() }
        }
    }

    func startListening() async {
        do {
            try await audio.start(micSource: micSource)
            listening = true
            lastError = nil
            // Before the conversation starts, so the Photos prompt never interrupts it.
            await PhotoSaver.requestAccessIfNeeded()
            // Auto-lock mid-conversation would cut the mic.
            UIApplication.shared.isIdleTimerDisabled = true
            route = AudioPipeline.routeDescription()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopListening() {
        audio.stop()
        listening = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func restartListening() async {
        stopListening()
        await startListening()
    }

    // MARK: Panic button

    /// Escape hatch: a fake incoming call so the wearer can "take this" and walk away.
    /// Listening pauses while the call is up and resumes when it ends.
    func triggerPanic() {
        guard panic == .idle else { return }
        panicTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var left = self.panicDelaySeconds
            while left > 0 {
                self.panic = .countdown(secondsLeft: left)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                left -= 1
            }
            self.ring()
        }
    }

    func cancelPanic() {
        panicTask?.cancel()
        panicTask = nil
        if case .countdown = panic { panic = .idle }
    }

    private func ring() {
        resumeListeningAfterPanic = listening
        if listening { stopListening() }
        panic = .ringing
        panicCallScreenOpen = false
        panicOnCallKit = panicUsesCallKit && UIApplication.shared.applicationState != .active
        if panicOnCallKit {
            callKit.ring(from: panicCallerName) { [weak self] error in
                guard let self, let error else { return }
                // CallKit refused (e.g. Do Not Disturb): fall back to our own banner.
                self.lastError = "iOS call screen unavailable (\(error.localizedDescription)); using the built-in one."
                self.panicUsesCallKit = false
                self.panicOnCallKit = false
                self.startRinging()
            }
        } else {
            startRinging()
        }
    }

    /// Answering from the banner stays in the pill. On CallKit the system pill opens the
    /// app, so it has to land on the call.
    func answerFakeCall() {
        stopRinging()
        if panicOnCallKit { panicCallScreenOpen = true }
        panic = .inCall(since: .now)
    }

    func openCallScreen() {
        panicCallScreenOpen = true
    }

    func minimizeCallScreen() {
        panicCallScreenOpen = false
    }

    func endFakeCall() {
        guard panic != .idle else { return }
        stopRinging()
        callKit.hangUp()
        panic = .idle
        panicCallScreenOpen = false
        panicOnCallKit = false
        if resumeListeningAfterPanic {
            resumeListeningAfterPanic = false
            Task { await startListening() }
        }
    }

    /// Rings out loud on the iPhone speaker and buzzes, like an incoming call.
    private func startRinging() {
        ringtone.start()
        vibrationTask?.cancel()
        vibrationTask = Task { @MainActor in
            while !Task.isCancelled {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                try? await Task.sleep(for: .seconds(1.4))
            }
        }
    }

    private func stopRinging() {
        ringtone.stop()
        vibrationTask?.cancel()
        vibrationTask = nil
    }

    /// The next sentence the wearer says teaches the backend how loud their own voice is.
    private func sendPersona() {
        client.send(json: ["type": "set_persona", "persona": persona.rawValue])
    }

    /// The next sentence `who` says becomes their voice sample.
    func calibrate(_ who: Speaker) {
        client.send(json: ["type": "calibrate", "who": who == .them ? "them" : "me"])
        calibration = .sampling(who)
    }

    /// Carry on with only the wearer's sample.
    func skipCalibratingThem() {
        calibration = .done(bothVoices: false)
    }

    /// Pretend the other person said `text` (skips speech-to-text). For testing and demo fallback.
    func sendTestLine(_ text: String) {
        client.send(json: ["type": "debug_turn", "text": text, "speaker": "them"])
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .ready:
            // A new backend session hasn't heard the wearer's voice yet.
            connection = .connected
            reconnectAttempt = 0
            calibration = .none
            lastError = nil
            // A new backend session starts on the default persona.
            sendPersona()
        case let .transcript(id, text, final, speaker):
            if final {
                partial = ""
                // The same id again means the brain decided who said it; update the label.
                if let i = lines.firstIndex(where: { $0.id == id }) {
                    lines[i].speaker = speaker
                } else {
                    lines.append(TranscriptLine(id: id, text: text, speaker: speaker))
                }
            } else {
                partial = text
            }
        case let .whisper(_, text):
            currentWhisper = text
        case let .risk(score):
            risk = score
        case let .taskStarted(id, _, label):
            tasks.append(ProofTask(id: id, label: label))
        case let .taskDone(id, _, _, imageUrl, _, _):
            let url = imageUrl.flatMap(URL.init(string:))
            if let i = tasks.firstIndex(where: { $0.id == id }) {
                tasks[i].done = true
                tasks[i].imageUrl = url
            }
            if let url { Task { await savePhoto(url) } }
        case let .whisperAudioStart(_, sampleRate):
            audio.setPlaybackSampleRate(Double(sampleRate))
            speaking = true
        case let .calibrated(who, ok):
            let speaker: Speaker = who == "them" ? .them : .me
            if !ok {
                calibration = .failed(speaker)
            } else {
                calibration = speaker == .me ? .needThem : .done(bothVoices: true)
            }
        case let .error(message):
            lastError = message
        case .whisperAudioEnd:
            speaking = false
        case .pong:
            break
        }
    }

    private func savePhoto(_ url: URL) async {
        let image: UIImage
        do {
            image = try await PhotoSaver.download(from: url)
        } catch {
            lastError = error.localizedDescription
            return
        }
        // Show it right away, even if saving to the camera roll fails.
        lastPhoto = image
        lastPhotoSaved = false
        do {
            try await PhotoSaver.addToLibrary(image)
            lastPhotoSaved = true
        } catch {
            lastError = error.localizedDescription
        }
    }
}
