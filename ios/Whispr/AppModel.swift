import Foundation
import Observation
import UIKit

struct TranscriptLine: Identifiable {
    let id: String
    var text: String
    var speaker: Speaker
}

struct ProofTask: Identifiable {
    let id: String
    var label: String
    var done = false
    var imageUrl: URL?
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
    var risk: Double = 0
    var tasks: [ProofTask] = []
    var lastError: String?

    var lastPhoto: UIImage?

    var backendURL: String {
        didSet { UserDefaults.standard.set(backendURL, forKey: "backendURL") }
    }

    var micSource: MicSource {
        didSet {
            UserDefaults.standard.set(micSource.rawValue, forKey: "micSource")
            if listening { Task { await restartListening() } }
        }
    }

    private let client = BackendClient()
    private let audio = AudioPipeline()

    init() {
        backendURL = UserDefaults.standard.string(forKey: "backendURL") ?? "ws://192.168.1.10:8787/ws"
        micSource = MicSource(rawValue: UserDefaults.standard.string(forKey: "micSource") ?? "") ?? .airpods

        let client = client
        audio.onMicChunk = { chunk in client.send(audio: chunk) }
        let audio = audio
        client.onAudio = { data in audio.play(data) }
        client.onEvent = { [weak self] event in Task { @MainActor in self?.handle(event) } }
        client.onDisconnect = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.connection = .disconnected
                if self.listening { self.stopListening() }
                if let error { self.lastError = error.localizedDescription }
            }
        }
    }

    func connect() {
        guard let url = URL(string: backendURL) else {
            lastError = "Bad backend URL"
            return
        }
        connection = .connecting
        client.connect(to: url)
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
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopListening() {
        audio.stop()
        listening = false
    }

    private func restartListening() async {
        stopListening()
        await startListening()
    }

    /// Pretend the other person said `text` (skips speech-to-text). For testing and demo fallback.
    func sendTestLine(_ text: String) {
        client.send(json: ["type": "debug_turn", "text": text, "speaker": "them"])
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .ready:
            connection = .connected
            lastError = nil
        case let .transcript(id, text, final, speaker):
            if final {
                partial = ""
                lines.append(TranscriptLine(id: id, text: text, speaker: speaker))
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
        case let .error(message):
            lastError = message
        case .whisperAudioEnd, .pong:
            break
        }
    }

    private func savePhoto(_ url: URL) async {
        do {
            lastPhoto = try await PhotoSaver.save(from: url)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
