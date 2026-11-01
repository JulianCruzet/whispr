// EARS & VOICE (owner: Julian + Claude)
// Captures the conversation as PCM16 mono 16 kHz for the backend, and plays the
// whisper audio (PCM16 mono) that streams back, into the AirPods.

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
    private var configObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private static let chunkBytes = 3200 // 100 ms at 16 kHz, 16-bit

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
    }

    func start(micSource: MicSource) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw AudioPipelineError.micPermissionDenied }
        self.micSource = micSource
        try configureSession()
        try startEngine()

        // AirPods connecting/disconnecting changes the input format and stops the engine.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            try? self.configureSession()
            try? self.startEngine()
        }

        // A phone call, Siri or an alarm pauses our audio; pick up again when it's over.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended
            else { return }
            try? self.configureSession()
            try? self.startEngine()
        }
    }

    func stop() {
        for observer in [configObserver, interruptionObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        configObserver = nil
        interruptionObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        pendingMic.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        player.scheduleBuffer(buffer)
        if engine.isRunning && !player.isPlaying { player.play() }
    }

    // MARK: Setup

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        switch micSource {
        case .airpods:
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        case .iphone:
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
        }
        try session.setActive(true)

        // Picking the input also picks the output: choosing the headphones' mic
        // pulls the whisper onto the headphones instead of the iPhone earpiece.
        let wanted: AVAudioSession.Port = micSource == .airpods ? .bluetoothHFP : .builtInMic
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
        guard let converter else { return }
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
