# Phone ⇄ backend protocol

One WebSocket per phone at `/ws`. Source of truth: `backend/src/protocol.ts` (mirrored in `ios/Whispr/Net/Protocol.swift`).

## Phone → backend

| Frame | Content |
|---|---|
| binary | Mic audio: PCM signed 16-bit little-endian, mono, **16 kHz**, ~100 ms per frame |
| text | `{"type":"hello","device":"iphone","sampleRate":16000}` on connect |
| text | `{"type":"debug_turn","text":"...","speaker":"them"}`: pretend someone said `text` (skips speech-to-text). Testing and demo fallback |
| text | `{"type":"calibrate"}`: the next line spoken is the wearer; the backend learns how loud their voice is |
| text | `{"type":"set_persona","persona":"first_date"}`: who the wearer is playing: `fan` (default), `interview`, `first_date` or `car_salesman`. Send it on every `ready` and when it changes. Changing it clears the conversation so far |
| text | `{"type":"ping"}` |

## Backend → phone

| Frame | Content |
|---|---|
| text | `ready` `{sessionId, integrations}`: sent on connect; `integrations` says which services are live vs. mock |
| text | `transcript` `{id, text, final, speaker}`: `final:false` is a live partial (id `"partial"`), `final:true` is a finished turn. `speaker` is `me` / `them` / `unknown` (see below) |
| text | `whisper` `{id, text}`: the line to say. Show it big on screen |
| text | `whisper_audio_start` `{id, sampleRate}` → binary frames → `whisper_audio_end` `{id}`: the spoken whisper, PCM16 mono at `sampleRate` (24 kHz) |
| text | `risk` `{score}`: 0..1, how close you are to getting caught |
| text | `task_started` `{id, kind, label}`: e.g. finding a photo |
| text | `task_done` `{id, kind, ok, imageUrl?, caption?, emailed?}` |
| text | `calibrated` `{ok, levelDb?}`: reply to `calibrate` once the wearer's line arrives |
| text | `error` `{message}`, `pong` |

## When is a turn finished?

- Normally when ElevenLabs Scribe hears ~0.6 s of silence.
- **Questions go out early:** if the live transcript ends in `?` and doesn't change for 300 ms, it's sent as a finished turn right away. Anything said after it in the same breath follows as its own turn.

## Who said it?

Scribe realtime doesn't label speakers, so the backend uses loudness: with headphones on, the wearer is much louder in the mic than the person across from them. After `calibrate`, lines within 8 dB of the wearer's level are `me`, quieter ones are `them`. Before calibrating, everything is `unknown`. Lines from `me` never get a whisper.

## Dashboard

`/ws/dashboard` receives a copy of every JSON event above (no audio), for a mission-control screen on a laptop or projector.
