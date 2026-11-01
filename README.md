# whispr

An earpiece that helps you larp. Whispr listens to your conversation, whispers the perfect next line into your AirPods, and when you're bluffing it goes and finds the proof, then tells you it's on your phone.

Built at LarpHacks 2026 (Nov 1, UofT). Submission cutoff: **6:00 PM**.

## How it works

```
iPhone app (SwiftUI)                         backend (Node + TS, on Render)
  mic ──PCM16 16 kHz──► WebSocket /ws ──►  ears/scribe.ts   ElevenLabs Scribe realtime
                                                │ committed turn
                                                ▼
                                           brain/index.ts
                                             ├─ brain/jev.ts       Jev: whisper? task? risk?
                                             ├─ brain/whisper.ts   Claude Haiku 5.5: the line
                                             └─ tasks/             photo search + Agentboxd email
                                                │
  AirPods ◄──PCM16 24 kHz── WebSocket ◄──  voice/tts.ts     ElevenLabs Flash TTS
  screen  ◄──JSON events──────────────────  (also mirrored to /ws/dashboard)
```

The full message format is in [docs/protocol.md](docs/protocol.md).

## Team split

| Area | Owner | Files |
|---|---|---|
| **Ears & voice**: mic capture, Scribe, TTS, AirPods playback | Julian | `ios/Whispr/Audio/`, `backend/src/ears/`, `backend/src/voice/` |
| **Brain & tasks**: Jev, whisper prompt, photo search, Agentboxd | Person B | `backend/src/brain/`, `backend/src/tasks/` |
| **Face & stage**: app UI, dashboard, Render deploy, demo script | Person C | `ios/Whispr/Views/`, `backend/` dashboard, `render.yaml` |

Stay in your folders and conflicts stay rare. `protocol.ts` / `Protocol.swift` are shared: change them in a small PR of their own.

## Workflow

- `main` is protected by convention: **everything goes in through a PR.** Faye merges.
- Branch names: `ears/...`, `brain/...`, `face/...`.
- Never commit `.env` or keys.

## Backend

```bash
cd backend
cp .env.example .env     # fill in the keys you have; missing ones run in mock mode
npm install
npm run dev              # http://localhost:8787
```

Every integration falls back to a mock when its key is missing, so you can build without keys.

Test the brain with no audio:

```bash
curl -X POST localhost:8787/debug/turn -d '{"text":"wait, you saw Laufey live?","speaker":"them"}'
```

## iOS app

Needs Xcode 26+. The project is generated from `ios/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd ios && xcodegen && open Whispr.xcodeproj
```

Re-run `xcodegen` after adding or removing Swift files. In Xcode, pick your team under Signing & Capabilities, plug in your iPhone and hit Run. In the app's settings, set the backend URL to `ws://<laptop-ip>:8787/ws` (same Wi-Fi), or the Render URL (`wss://.../ws`).

## Keys

| Key | Where to get it |
|---|---|
| `ELEVENLABS_API_KEY` | ElevenLabs Discord → coupon-codes → LarpHacks coupon |
| `JEV_API_KEY` | console.typesafe.ai |
| `ANTHROPIC_API_KEY` | console.anthropic.com |
| `SERPAPI_KEY` | serpapi.com |
| `AGENTBOXD_API_KEY` | agentboxd, redeem `LARPHACKS-2026` |
