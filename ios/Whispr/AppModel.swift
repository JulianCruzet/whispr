import Foundation
import Observation

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

    var backendURL: String {
        didSet { UserDefaults.standard.set(backendURL, forKey: "backendURL") }
    }

    private let client = BackendClient()

    init() {
        backendURL = UserDefaults.standard.string(forKey: "backendURL") ?? "ws://192.168.1.10:8787/ws"
        client.onEvent = { [weak self] event in Task { @MainActor in self?.handle(event) } }
        client.onDisconnect = { [weak self] error in
            Task { @MainActor in
                self?.connection = .disconnected
                self?.listening = false
                if let error { self?.lastError = error.localizedDescription }
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
        // TODO(ears & voice): start/stop mic streaming and whisper playback.
        listening.toggle()
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
            if let i = tasks.firstIndex(where: { $0.id == id }) {
                tasks[i].done = true
                tasks[i].imageUrl = imageUrl.flatMap(URL.init(string:))
            }
        case let .error(message):
            lastError = message
        case .whisperAudioStart, .whisperAudioEnd, .pong:
            break
        }
    }
}
