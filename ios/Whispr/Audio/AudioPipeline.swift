// EARS & VOICE (owner: Julian + Claude)
// Captures the conversation as PCM16 mono 16 kHz for the backend, and plays the
// whisper audio (PCM16 mono) that streams back, into the headphones or out of the
// iPhone's top or main speaker.

import AVFoundation

enum MicSource: String, CaseIterable, Identifiable {
    /// Bluetooth headphones (AirPods, Sony, ...) do both: listen and whisper (call mode).
    case airpods
    /// The iPhone's own mic listens (better at hearing the other person);
    /// headphones only whisper, in high-quality mode.
    case iphone

    var id: String { rawValue }
    var label: String { self == .airpods ? "Headphones mic" : "iPhone mic" }
}

/// Where whispers play.
enum VoiceOutput: String, CaseIterable, Identifiable {
    /// Bluetooth headphones, or the top speaker while none are connected.
    case headphones
    /// The earpiece at the top of the phone: quiet, so only the wearer hears it.
    case topSpeaker
    /// The loudspeaker: the other person hears it too.
    case speaker

    var id: String { rawValue }
    var label: String {
        switch self {
        case .headphones: "Headphones"
        case .topSpeaker: "Top speaker"
        case .speaker: "iPhone speaker"
        }
    }
}

enum AudioPipelineError: LocalizedError {
    case micPermissionDenied
    case noInput

    var errorDescription: String? {
        switch self {
        case .micPermissionDenied: "Microphone access is off. Turn it on in Settings → Whispr."
        case .noInput: "No microphone available."
        }
    }
}

final class AudioPipeline: @unchecked Sendable {
    /// Called on the audio thread with ~100 ms of PCM16 mono 16 kHz audio.
    var onMicChunk: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var playerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var pendingMic = Data()
    private var playbackCarry: UInt8?
    private var micSource: MicSource = .airpods
    private var voiceOutput: VoiceOutput = .headphones
    /// When the whisper queued on the speaker finishes. Touched by both audio threads.
    private var speakerWhisperEndsAt = Date.distantPast
    private let whisperLock = NSLock()
    private var configObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    /// Between start() and stop(). Main thread only, like `recovering`.
    private var running = false
    private var recovering = false
    private static let recoverAttempts = 6
    private static let recoverDelay: TimeInterval = 0.5
    private static let chunkBytes = 3200 // 100 ms at 16 kHz, 16-bit
    /// Keep the mic shut this long after a whisper, for the speaker to fall quiet.
    private static let speakerTail: TimeInterval = 0.3

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
    }

    func start(micSource: MicSource, voiceOutput: VoiceOutput) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw AudioPipelineError.micPermissionDenied }
        self.micSource = micSource
        self.voiceOutput = voiceOutput
        try configureSession()
        try startEngine()
        await MainActor.run { running = true }

        // AirPods connecting/disconnecting changes the input format and stops the engine.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.recover()
        }

        // Headphones can vanish from the input list for a moment as Bluetooth switches
        // modes, which leaves the voice on the earpiece until something pulls it back.
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reclaimHeadphones()
        }

        // A phone call, Siri or an alarm pauses our audio; pick up again when it's over.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended
            else { return }
            self.recover()
        }
    }

    func stop() {
        running = false
        for observer in [configObserver, interruptionObserver, routeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        configObserver = nil
        interruptionObserver = nil
        routeObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        pendingMic.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Restarts the audio on the main thread. The route is often still settling, so a
    /// failed try is repeated instead of leaving the mic and voice dead until Stop → Start.
    private func recover(attempt: Int = 1) {
        guard running, attempt > 1 || !recovering else { return }
        recovering = true
        do {
            try configureSession()
            try startEngine()
            recovering = false
        } catch {
            guard attempt < Self.recoverAttempts else {
                recovering = false
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.recoverDelay) { [weak self] in
                self?.recover(attempt: attempt + 1)
            }
        }
    }

    private func reclaimHeadphones() {
        guard running, voiceOutput == .headphones, micSource == .airpods else { return }
        let session = AVAudioSession.sharedInstance()
        guard session.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }),
              let headphones = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP })
        else { return }
        try? session.setPreferredInput(headphones)
    }

    // MARK: Whisper playback

    /// Prepare for whisper audio at `sampleRate` (sent in whisper_audio_start).
    func setPlaybackSampleRate(_ sampleRate: Double) {
        guard sampleRate != playerFormat.sampleRate,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        else { return }
        playerFormat = format
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Queue PCM16 mono little-endian whisper audio; plays as soon as it arrives.
    /// Whisper buffers scheduled but not yet heard. Streaming finishes well before playback,
    /// so this, not the stream, says whether the ear is still busy.
    private let queuedLock = NSLock()
    private var queuedBuffers = 0
    var isPlayingWhisper: Bool { queuedLock.withLock { queuedBuffers > 0 } }

    /// Calls `reached` once playback gets to this point in the queue: the start of the whisper
    /// that streams next. The card switches to that line then, so it matches what's heard.
    func markPlayback(_ reached: @escaping @Sendable () -> Void) {
        guard let marker = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: 1),
              let out = marker.floatChannelData?[0]
        else { return reached() }
        marker.frameLength = 1
        out[0] = 0
        player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack) { _ in reached() }
        if engine.isRunning && !player.isPlaying { player.play() }
    }

    func play(_ data: Data) {
        var bytes = data
        if let carry = playbackCarry {
            bytes.insert(carry, at: bytes.startIndex)
            playbackCarry = nil
        }
        if bytes.count % 2 == 1 { playbackCarry = bytes.removeLast() }

        let frames = bytes.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        bytes.withUnsafeBytes { raw in
            for i in 0..<frames {
                out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }
        queuedLock.withLock { queuedBuffers += 1 }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.queuedLock.withLock { self.queuedBuffers = max(0, self.queuedBuffers - 1) }
        }
        if engine.isRunning {
            if !player.isPlaying { player.play() }
        } else {
            // Nothing told us the engine stopped; a whisper is the first sign.
            DispatchQueue.main.async { [weak self] in self?.recover() }
        }
        if Self.playingOnSpeaker { extendSpeakerWhisper(by: Double(frames) / playerFormat.sampleRate) }
    }

    private static var playingOnSpeaker: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }

    private func extendSpeakerWhisper(by seconds: TimeInterval) {
        whisperLock.lock()
        defer { whisperLock.unlock() }
        speakerWhisperEndsAt = max(speakerWhisperEndsAt, Date()).addingTimeInterval(seconds)
    }

    /// The mic would hear the speaker, and Whispr would coach itself.
    private var speakerWhisperIsAudible: Bool {
        whisperLock.lock()
        defer { whisperLock.unlock() }
        return Date() < speakerWhisperEndsAt.addingTimeInterval(Self.speakerTail)
    }

    // MARK: Setup

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Leaving Bluetooth out of the speaker options keeps the voice on the phone
        // even if headphones are connected.
        let options: AVAudioSession.CategoryOptions
        switch voiceOutput {
        case .headphones: options = micSource == .airpods ? [.allowBluetoothHFP, .allowBluetoothA2DP] : [.allowBluetoothA2DP]
        case .topSpeaker: options = []
        case .speaker: options = [.defaultToSpeaker]
        }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true)

        // Picking the input also picks the output: choosing the headphones' mic
        // pulls the whisper onto the headphones instead of the iPhone earpiece.
        let wanted: AVAudioSession.Port = voiceOutput == .headphones && micSource == .airpods ? .bluetoothHFP : .builtInMic
        if let input = session.availableInputs?.first(where: { $0.portType == wanted }) {
            try session.setPreferredInput(input)
        }
    }

    /// Where audio is coming from and going to right now, e.g. "Mic: WH-1000XM5 · Voice: WH-1000XM5".
    static func routeDescription() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let mic = route.inputs.first?.portName ?? "none"
        guard let out = route.outputs.first else { return "Mic: \(mic) · Voice: none" }
        let voice = out.portType == .builtInReceiver ? "iPhone earpiece ⚠️ connect headphones" : out.portName
        return "Mic: \(mic) · Voice: \(voice)"
    }

    private func startEngine() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw AudioPipelineError.noInput }

        converter = AVAudioConverter(from: inputFormat, to: micFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.forwardMic(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play()
    }

    private func forwardMic(_ buffer: AVAudioPCMBuffer) {
        guard let converter, !speakerWhisperIsAudible else { return }
        let ratio = micFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }

        pendingMic.append(Data(bytes: samples, count: Int(out.frameLength) * 2))
        while pendingMic.count >= Self.chunkBytes {
            onMicChunk?(pendingMic.prefix(Self.chunkBytes))
            pendingMic.removeFirst(Self.chunkBytes)
        }
    }
}
