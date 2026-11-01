# Phone ⇄ backend protocol

One WebSocket per phone at `/ws`. Source of truth: `backend/src/protocol.ts` (mirrored in `ios/Whispr/Net/Protocol.swift`).

## Phone → backend

| Frame | Content |
|---|---|
| binary | Mic audio: PCM signed 16-bit little-endian, mono, **16 kHz**, ~100 ms per frame |
| text | `{"type":"hello","device":"iphone","sampleRate":16000}` on connect |
| text | `{"type":"ping"}` |

## Backend → phone

| Frame | Content |
|---|---|
| text | `ready` `{sessionId, integrations}`: sent on connect; `integrations` says which services are live vs. mock |
| text | `transcript` `{id, text, final, speaker}`: `final:false` is a live partial (id `"partial"`), `final:true` is a finished turn. `speaker` is `me` / `them` / `unknown` |
| text | `whisper` `{id, text}`: the line to say. Show it big on screen |
| text | `whisper_audio_start` `{id, sampleRate}` → binary frames → `whisper_audio_end` `{id}`: the spoken whisper, PCM16 mono at `sampleRate` (24 kHz) |
| text | `risk` `{score}`: 0..1, how close you are to getting caught |
| text | `task_started` `{id, kind, label}`: e.g. finding a photo |
| text | `task_done` `{id, kind, ok, imageUrl?, caption?, emailed?}` |
| text | `error` `{message}`, `pong` |

## Dashboard

`/ws/dashboard` receives a copy of every JSON event above (no audio), for a mission-control screen on a laptop or projector.
