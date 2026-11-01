// Wire protocol between the app and the backend.
// Keep in sync with backend/src/protocol.ts. See docs/protocol.md.

import Foundation

enum Speaker: String, Codable {
    case me, them, unknown
}

/// JSON text frames from the backend. Binary frames are whisper audio
/// (PCM16 mono at the sample rate from the preceding `whisperAudioStart`).
enum ServerEvent {
    case ready(sessionId: String, integrations: [String: Bool])
    case transcript(id: String, text: String, final: Bool, speaker: Speaker)
    case whisper(id: String, text: String)
    case whisperAudioStart(id: String, sampleRate: Int)
    case whisperAudioEnd(id: String)
    case risk(score: Double)
    case taskStarted(id: String, kind: String, label: String)
    case taskDone(id: String, kind: String, ok: Bool, imageUrl: String?, caption: String?, emailed: Bool?)
    case calibrated(ok: Bool, levelDb: Double?)
    case error(message: String)
    case pong
}

extension ServerEvent: Decodable {
    private enum Key: String, CodingKey {
        case type, sessionId, integrations, id, text, final, speaker, sampleRate, score
        case kind, label, ok, imageUrl, caption, emailed, message, levelDb
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "ready":
            self = .ready(sessionId: try c.decode(String.self, forKey: .sessionId),
                          integrations: try c.decodeIfPresent([String: Bool].self, forKey: .integrations) ?? [:])
        case "transcript":
            self = .transcript(id: try c.decode(String.self, forKey: .id),
                               text: try c.decode(String.self, forKey: .text),
                               final: try c.decode(Bool.self, forKey: .final),
                               speaker: (try? c.decode(Speaker.self, forKey: .speaker)) ?? .unknown)
        case "whisper":
            self = .whisper(id: try c.decode(String.self, forKey: .id), text: try c.decode(String.self, forKey: .text))
        case "whisper_audio_start":
            self = .whisperAudioStart(id: try c.decode(String.self, forKey: .id),
                                      sampleRate: try c.decode(Int.self, forKey: .sampleRate))
        case "whisper_audio_end":
            self = .whisperAudioEnd(id: try c.decode(String.self, forKey: .id))
        case "risk":
            self = .risk(score: try c.decode(Double.self, forKey: .score))
        case "task_started":
            self = .taskStarted(id: try c.decode(String.self, forKey: .id),
                                kind: try c.decode(String.self, forKey: .kind),
                                label: try c.decode(String.self, forKey: .label))
        case "task_done":
            self = .taskDone(id: try c.decode(String.self, forKey: .id),
                             kind: try c.decode(String.self, forKey: .kind),
                             ok: try c.decode(Bool.self, forKey: .ok),
                             imageUrl: try c.decodeIfPresent(String.self, forKey: .imageUrl),
                             caption: try c.decodeIfPresent(String.self, forKey: .caption),
                             emailed: try c.decodeIfPresent(Bool.self, forKey: .emailed))
        case "calibrated":
            self = .calibrated(ok: try c.decode(Bool.self, forKey: .ok),
                               levelDb: try c.decodeIfPresent(Double.self, forKey: .levelDb))
        case "error":
            self = .error(message: try c.decode(String.self, forKey: .message))
        case "pong":
            self = .pong
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown event \(type)")
        }
    }
}
