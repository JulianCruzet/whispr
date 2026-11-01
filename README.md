# whispr

An earpiece that helps you larp. Whispr listens to your conversation, whispers the perfect next line into your AirPods, and when you're bluffing it goes and finds the proof, then tells you it's on your phone.

Built at LarpHacks 2026 (Nov 1, UofT). Submission cutoff: **6:00 PM**.

## How it works

Two backend services in `backend/`, one `.env`:

```
iPhone app (SwiftUI)              audio gateway (Node, src/, :8787)           brain (Python, app/, :8000)
  mic ─PCM16 16 kHz─► /ws ──►  ears/scribe.ts   ElevenLabs Scribe
                                 │ finished line + me/them (loudness)
                                 └──────────────── /ws ─────────────────►  Jev: who spoke? whisper? task?
                                                                            Claude Haiku 5.5: the line
                                                                            photo search (Brave) + fallback
                                 ┌──────── whisper / task events ◄───────┘
  headphones ◄─PCM16 24 kHz─  voice/tts.ts     ElevenLabs Flash TTS (one whisper at a time)
  screen ◄─JSON events──────  (also mirrored to /ws/dashboard)
```

The full message format is in [docs/protocol.md](docs/protocol.md).

## Team split

| Area | Owner | Files |
|---|---|---|
| **Ears & voice**: mic capture, Scribe, TTS, headphone playback, gateway | Julian | `ios/Whispr/Audio/`, `backend/src/` |
| **Brain & tasks**: Jev, whisper prompt, photo search | Person B | `backend/app/`, `backend/tests/` |
| **Face & stage**: app UI, dashboard, Render deploy, demo script | Person C | `ios/Whispr/Views/`, `backend/` dashboard, `render.yaml` |

Stay in your folders and conflicts stay rare. `protocol.ts` / `Protocol.swift` are shared: change them in a small PR of their own.

## Workflow

- `main` is protected by convention: **everything goes in through a PR.** Faye merges.
- Branch names: `ears/...`, `brain/...`, `face/...`.
- Never commit `.env` or keys.

## Backend

```bash
cd backend
cp .env.example .env     # fill in the keys you have
./scripts/dev.sh         # brain on :8000 + gateway on :8787 (Ctrl+C stops both)
```

The first run sets up a Python venv and `npm install`. Details on the brain, its tests and its message format: [backend/README.md](backend/README.md).

Automated tests: `npm test` (gateway) and `.venv/bin/python -m pytest` (brain), both from `backend/`.

Test without talking:

```bash
npx tsx scripts/fake-phone.ts "wait, you saw Laufey live?"            # typed line as "them"
npx tsx scripts/fake-phone.ts --calibrate --wav conversation.wav       # 16 kHz mono WAV, first line = you
curl -X POST localhost:8000/transcript -H 'content-type: application/json' \
  -d '{"text":"wait, you saw Laufey live?","speaker":"them"}'          # brain only
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
| `BRAVE_SEARCH_API_KEY` | brave.com/search/api (photo search; without it the cached photo is used) |
