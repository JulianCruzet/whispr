// PANIC (owner: Julian + Claude)
// An original marimba-style ringtone, synthesized at runtime (apps can't use the
// system ringtones), played out loud on the iPhone speaker so the other person hears
// the phone ring even if the wearer has headphones on.

import AVFoundation

final class Ringtone {
    private var player: AVAudioPlayer?

    func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            // Force the speaker even when Bluetooth headphones are connected.
            try session.overrideOutputAudioPort(.speaker)
            let player = try AVAudioPlayer(data: Self.wav)
            player.numberOfLoops = -1
            player.volume = 1
            player.play()
            self.player = player
        } catch {
            player = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(.none)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Synthesis

    private static let sampleRate = 44100.0

    /// One loop: a rising-falling marimba phrase played twice, then a pause (~2.4 s).
    private static let wav: Data = {
        // (start time in seconds, frequency in Hz)
        let phrase: [(Double, Double)] = [
            (0.00, 659.25), (0.14, 987.77), (0.28, 1318.51), (0.42, 987.77),
            (0.70, 659.25), (0.84, 987.77), (0.98, 1318.51), (1.12, 987.77),
        ]
        let length = 2.4
        var samples = [Float](repeating: 0, count: Int(length * sampleRate))
        for (start, frequency) in phrase {
            addMarimbaNote(frequency: frequency, at: start, into: &samples)
        }
        let peak = samples.map(abs).max() ?? 1
        let pcm = samples.map { Int16(max(-1, min(1, $0 / peak * 0.9)) * 32767) }
        return wavData(pcm)
    }()

    /// A struck bar: fundamental plus a quieter 4th harmonic, both decaying fast.
    private static func addMarimbaNote(frequency: Double, at start: Double, into samples: inout [Float]) {
        let first = Int(start * sampleRate)
        let count = min(Int(0.45 * sampleRate), samples.count - first)
        guard count > 0 else { return }
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let attack = min(1, t / 0.004)
            let body = sin(2 * .pi * frequency * t) * exp(-t * 7)
            let overtone = 0.35 * sin(2 * .pi * frequency * 4 * t) * exp(-t * 22)
            samples[first + i] += Float(attack * (body + overtone))
        }
    }

    private static func wavData(_ pcm: [Int16]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)) // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for sample in pcm { append(sample) }
        return data
    }
}
