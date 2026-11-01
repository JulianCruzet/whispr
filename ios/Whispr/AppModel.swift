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
    /// The short cue Whispr says in the ear for currentWhisper, shown big so what's heard is on screen.
    var currentCue: String?
    /// Lines whose audio hasn't reached the ear yet, by whisper id (see `showWhisper`).
    private var waitingWhispers: [String: (text: String, spoken: String?)] = [:]
    /// "The photo's in your camera roll…", shown with the proof photo.
    var photoNotice: String?
    /// Whispr's voice is streaming into the wearer's ear right now.
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
        /// Listening to this person: `heard` seconds of their speech so far, out of
        /// `target` (nil until the backend reports after their first line).
        case sampling(Speaker, heard: Double = 0, target: Double? = nil)
        /// The wearer's sample is in; ask for the other person's.
        case needThem
        /// This person's sample couldn't be used: too little speech, or (for them) it was
        /// the wearer talking.
        case failed(Speaker, soundedLikeYou: Bool = false)
        /// Both samples, or the wearer's only (then the backend judges by the wearer's voice alone).
        case done(bothVoices: Bool)
    }
    var calibration: Calibration = .none
    /// How much speech each calibration step collects: quick (a few seconds), or 15 s each
    /// from Settings, for a demo where it has to be exactly right.
    enum CalibrationLength: Equatable {
        case quick, demo
        var seconds: Double? { self == .demo ? 15 : nil }
    }
    private(set) var calibrationLength: CalibrationLength = .quick
    /// Whose voice samples the backend has, for the header's voices chip. A failed retry
    /// keeps the old sample, so it only ever grows until a new backend session.
    private(set) var calibratedVoices: Set<Speaker> = []
    /// The wearer chose to go on without the other person's sample; a reconnect keeps that.
    private var skippedThem = false

    var lastPhoto: UIImage?
    /// Whether lastPhoto made it into the camera roll.
    var lastPhotoSaved = false
    /// The photo full screen in the app, when it isn't in (or Photos won't open to) the camera roll.
    var showsPhotoFullScreen = false

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
    /// Real iOS call screen (CallKit). Off: our own full-screen call screen, which always shows full screen.
    var panicUsesCallKit: Bool {
        didSet { UserDefaults.standard.set(panicUsesCallKit, forKey: "panicUsesCallKit") }
    }
    var panicDelaySeconds: Int {
        didSet { UserDefaults.standard.set(panicDelaySeconds, forKey: "panicDelaySeconds") }
    }

    /// Our own call screen is up. CallKit draws its own while ringing, but once answered
    /// the call pill opens the app, so it has to land on the call.
    var showsFakeCallScreen: Bool {
        switch panic {
        case .ringing: !panicUsesCallKit
        case .inCall: true
        case .idle, .countdown: false
        }
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

    var voiceOutput: VoiceOutput {
        didSet {
            UserDefaults.standard.set(voiceOutput.rawValue, forKey: "voiceOutput")
            if listening { Task { await restartListening() } }
        }
    }

    var persona: Persona {
        didSet {
            UserDefaults.standard.set(persona.rawValue, forKey: "persona")
            sendPersona()
        }
    }

    /// Strict turn-taking for a rigged demo: the wearer speaks first, then them, then the
    /// wearer, whatever the voices sound like.
    var takeTurns = false {
        didSet {
            UserDefaults.standard.set(takeTurns, forKey: "takeTurns")
            sendTurns()
        }
    }
    /// Who the next line will be labelled as, while turn-taking is on.
    private(set) var nextTurn: Speaker?

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
        voiceOutput = VoiceOutput(rawValue: UserDefaults.standard.string(forKey: "voiceOutput") ?? "") ?? .headphones
        persona = Persona(rawValue: UserDefaults.standard.string(forKey: "persona") ?? "") ?? .fan
        panicCallerName = UserDefaults.standard.string(forKey: "panicCallerName") ?? "Mom"
        panicUsesCallKit = UserDefaults.standard.bool(forKey: "panicUsesCallKit")
        takeTurns = UserDefaults.standard.bool(forKey: "takeTurns")
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
        client.connect(to: url, deviceId: UIDevice.current.identifierForVendor?.uuidString)
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
            try await audio.start(micSource: micSource, voiceOutput: voiceOutput)
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
        if panicUsesCallKit {
            callKit.ring(from: panicCallerName) { [weak self] error in
                guard let self, let error else { return }
                // CallKit refused (e.g. Do Not Disturb): fall back to our own screen.
                self.lastError = "iOS call screen unavailable (\(error.localizedDescription)); using the built-in one."
                self.panicUsesCallKit = false
                self.startRinging()
            }
        } else {
            startRinging()
        }
    }

    func answerFakeCall() {
        stopRinging()
        panic = .inCall(since: .now)
    }

    func endFakeCall() {
        guard panic != .idle else { return }
        stopRinging()
        callKit.hangUp()
        panic = .idle
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

    /// Puts a waiting line on the card (once; later calls for it do nothing).
    private func showWhisper(_ id: String) {
        guard let line = waitingWhispers.removeValue(forKey: id) else { return }
        currentWhisper = line.text
        currentCue = line.spoken
    }

    private func sendTurns() {
        client.send(json: ["type": "set_turns", "alternate": takeTurns])
    }

    /// Turn-taking slipped (a line split in two, say): swap who is next.
    func flipTurn() {
        client.send(json: ["type": "flip_turn"])
    }

    private func sendPersona() {
        client.send(json: ["type": "set_persona", "persona": persona.rawValue])
    }

    /// The next few lines `who` says become their voice sample.
    /// `length` switches between quick and demo calibration; left out, it keeps the last one,
    /// so the other person's step matches the wearer's.
    func calibrate(_ who: Speaker, length: CalibrationLength? = nil) {
        if let length { calibrationLength = length }
        var message: [String: Any] = ["type": "calibrate", "who": who == .them ? "them" : "me"]
        if let seconds = calibrationLength.seconds { message["seconds"] = seconds }
        client.send(json: message)
        calibration = .sampling(who, target: calibrationLength.seconds)
        if who == .them { skippedThem = false }
    }

    /// Stops a calibration step in progress (its page was closed) without keeping anything.
    func cancelCalibration() {
        guard case .sampling = calibration else { return }
        client.send(json: ["type": "cancel_calibration"])
        calibration = .none
    }

    /// Forgets both voices, calibrated or learnt, so new people can calibrate from scratch.
    func clearCalibration() {
        client.send(json: ["type": "clear_calibration"])
        calibratedVoices = []
        calibration = .none
        calibrationLength = .quick
        skippedThem = false
    }

    /// From Settings: 15 s of `who` talking, listening first if it isn't yet.
    func calibrateForDemo(_ who: Speaker) {
        Task {
            if !listening { await startListening() }
            if listening { calibrate(who, length: .demo) }
        }
    }

    /// Carry on with only the wearer's sample.
    func skipCalibratingThem() {
        calibration = .done(bothVoices: false)
        skippedThem = true
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
            // The backend replays the samples it kept for this phone right after this.
            calibratedVoices = []
            lastError = nil
            // A new backend session starts on the default persona.
            sendPersona()
            sendTurns()
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
        case let .whisper(id, text, spoken, reason):
            // The photo alert goes with the photo; the line the wearer is saying stays put.
            if reason == "photo_ready" {
                photoNotice = text
            } else {
                // The card shows a line when its audio starts in the ear, so it always matches
                // what's heard, even while an earlier line is still playing. With nothing
                // playing it shows at once; if its audio never comes, it shows after 8 s anyway.
                waitingWhispers[id] = (text, spoken)
                if !speaking && !audio.isPlayingWhisper {
                    showWhisper(id)
                } else {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(8))
                        self?.showWhisper(id)
                    }
                }
            }
        case let .risk(score):
            risk = score
        case let .taskStarted(id, _, label):
            photoNotice = nil
            lastPhoto = nil
            lastPhotoSaved = false
            tasks.append(ProofTask(id: id, label: label))
        case let .taskDone(id, _, _, imageUrl, _, _):
            let url = imageUrl.flatMap(URL.init(string:))
            if let i = tasks.firstIndex(where: { $0.id == id }) {
                tasks[i].done = true
                tasks[i].imageUrl = url
            }
            if let url { Task { await savePhoto(url) } }
        case let .whisperAudioStart(id, sampleRate):
            audio.setPlaybackSampleRate(Double(sampleRate))
            audio.prepareForWhisper(micSource: micSource, voiceOutput: voiceOutput)
            speaking = true
            route = AudioPipeline.routeDescription()
            // So the backend log shows where each whisper played, if one is ever not heard.
            client.send(json: [
                "type": "audio_state", "route": route, "engine": audio.isEngineRunning, "listening": listening,
            ])
            if waitingWhispers[id] != nil {
                audio.markPlayback { [weak self] in Task { @MainActor in self?.showWhisper(id) } }
            }
        case let .calibrating(who, seconds, target):
            let speaker: Speaker = who == "them" ? .them : .me
            if case .sampling(speaker, _, _) = calibration {
                calibration = .sampling(speaker, heard: seconds, target: target)
            }
        case let .calibrated(who, ok, reason):
            // Also arrives right after connecting, for samples the backend kept for this phone.
            let speaker: Speaker = who == "them" ? .them : .me
            if ok { calibratedVoices.insert(speaker) }
            if !ok {
                calibration = .failed(speaker, soundedLikeYou: reason == "sounds_like_you")
            } else if speaker == .them {
                calibration = .done(bothVoices: true)
            } else if calibration != .done(bothVoices: true) {
                calibration = skippedThem ? .done(bothVoices: false) : .needThem
            }
        case let .error(message):
            lastError = message
        case .whisperAudioEnd:
            speaking = false
        case let .turn(next):
            nextTurn = next
        case .pong:
            break
        }
    }

    /// Opens the Photos app, where the proof photo is the newest one. There's no public way
    /// to open one particular photo, so this opens the library; if the photo isn't saved or
    /// Photos won't open, it shows full screen here instead.
    func openPhoto() {
        guard lastPhoto != nil else { return }
        Task {
            let opened = lastPhotoSaved ? await UIApplication.shared.open(Self.photosApp) : false
            if !opened { showsPhotoFullScreen = true }
        }
    }

    private static let photosApp = URL(string: "photos-redirect://")!

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
