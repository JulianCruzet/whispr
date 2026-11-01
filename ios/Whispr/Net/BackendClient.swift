import Foundation

/// One WebSocket to the backend: mic audio and JSON go up, events and whisper audio come down.
final class BackendClient: NSObject, @unchecked Sendable {
    var onEvent: ((ServerEvent) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default)

    func connect(to url: URL) {
        disconnect()
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        send(json: ["type": "hello", "device": "iphone", "sampleRate": 16000])
        receive(on: task)
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Raw mic audio: PCM16 mono 16 kHz.
    func send(audio: Data) {
        task?.send(.data(audio)) { _ in }
    }

    func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, self.task === task else { return }
            switch result {
            case .success(.string(let text)):
                if let data = text.data(using: .utf8),
                   let event = try? JSONDecoder().decode(ServerEvent.self, from: data) {
                    self.onEvent?(event)
                }
                self.receive(on: task)
            case .success(.data(let data)):
                self.onAudio?(data)
                self.receive(on: task)
            case .success:
                self.receive(on: task)
            case .failure(let error):
                self.task = nil
                self.onDisconnect?(error)
            }
        }
    }
}
