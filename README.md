<div align="center">
  <img src="./ios/Whispr/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="Whispr" width="140"/>

  <h1>Whispr</h1>

  <p><strong>An earpiece that helps you larp.</strong></p>

  [![Swift](https://img.shields.io/badge/SwiftUI-iOS_17+-F05138)](https://developer.apple.com/xcode/swiftui/)
  [![Node.js](https://img.shields.io/badge/Node.js-20+-339933)](https://nodejs.org/)
  [![TypeScript](https://img.shields.io/badge/TypeScript-7-blue)](https://www.typescriptlang.org/)
  [![Python](https://img.shields.io/badge/Python-3.11+-3776AB)](https://www.python.org/)
  [![FastAPI](https://img.shields.io/badge/FastAPI-0.162-009688)](https://fastapi.tiangolo.com/)
  [![Claude](https://img.shields.io/badge/Claude-Haiku_5.5-D97757)](https://www.anthropic.com/claude)
  [![ElevenLabs](https://img.shields.io/badge/ElevenLabs-Scribe_+_Flash-000000)](https://elevenlabs.io/)

  Built at LarpHacks 2026 · [Quick Start](#-quick-start) · [Demo runbook](docs/demo-runbook.md) · [Protocol](docs/protocol.md)
</div>

---

## 🎬 Demo

You're bluffing being a Laufey fan with a *real* Laufey fan.

| | What happens |
|---|---|
| **They ask** | "Wait, you saw her live? Which show?" |
| **Your earpiece whispers** | *"Say you saw her at Massey Hall. Say the Bewitched tour was unreal"* |
| **They want proof** | "Do you have any pictures from that night?" |
| **Your earpiece buys time** | *"Say the Massey Hall one was unreal. Say give me a sec"* An agent is already looking for a photo in the background |
| **The proof lands** | *"Photo's on your phone. Show them now."* It's on screen and in your camera roll |
| **They push too hard** | Tap **Panic**. Your phone rings with a fake call. *"Sorry, I have to take this."* |

The whispered lines come from a real test run, and they change every time. To run the demo yourself, follow the [demo runbook](docs/demo-runbook.md).

## 🧭 Overview

Whispr is a lighthearted improv game for iPhone and headphones. It listens to your conversation, whispers the perfect next line into your ear, and goes and finds the proof when you're bluffing.

> *Like the Kingsman scene where Eggsy gets fed the right answers through his earpiece.*

### Why Whispr?

- **It waits for your cue.** Whispr only coaches after the other person's turn, never on your own words.
- **It's short enough to use.** Every line is capped at 15 words, because you have to hear it and say it mid-conversation.
- **It backs you up.** When someone asks for proof, a background task looks for a photo while you keep talking.
- **It gets you out.** When the bluff falls apart, a fake call gives you a reason to walk away.

---

## 🚀 Features

### 🎧 Ears & voice

| Feature | Description |
|---|---|
| **Live transcript** | ElevenLabs Scribe transcribes as people talk, and finished lines are labelled YOU or THEM |
| **Fast on questions** | A line ending in a question goes out after 300 ms instead of waiting for about 0.6 s of silence |
| **Knows who's talking** | You each say one sentence to calibrate, then a voiceprint of every line tells your voice from theirs, even at equal volume. If it isn't sure, Jev decides from the words |
| **Whispers in your ear** | ElevenLabs Flash speaks each line through your headphones, one at a time and never over each other |
| **Your choice of mic** | Listen with your headphones, or switch to the iPhone mic if they can't hear the other person |

### 🧠 Brain

| Feature | Description |
|---|---|
| **Fast decisions** | On each finished line, Jev decides who spoke, whether you need a line, whether to find a photo, and how close you are to being caught |
| **The line to say** | Claude Haiku 5.5 writes the words: one line, 15 words at most, built from the names and details in your conversation |
| **Won't talk over you** | At most one reply every 5 seconds, and only when Jev is confident you need one |
| **Cover-blown meter** | The app shows how close you are to being caught, updated with each line from the other person |
| **Survives failures** | If Jev or Haiku fails, the conversation keeps going and the next line tries again |

### 🎭 Personas

Choose who you're playing under **Settings → Persona**. Every persona follows whatever the conversation is actually about, and changing persona starts a new scene.

| Persona | The scene | Proof photos |
|---|---|---|
| **Superfan** (default) | You're into whatever they bring up, and you've been there or seen it | Search, then a cached photo |
| **Job interview** | A candidate in a mock interview, a little too polished | None |
| **First date** | Charming and curious on a pretend first date | Search only |
| **Car salesman** | An over-the-top used car sales sketch | Search only |

### 📸 Proof photos

| Feature | Description |
|---|---|
| **Background search** | Haiku writes the search query and Brave finds the image while the conversation continues |
| **Picks a believable shot** | Results that won't load are skipped, and it prefers a big portrait image that could pass for a phone photo |
| **Cached fallback** | If search fails or takes over 5 seconds, Superfan falls back to a known-good photo |
| **Made for the phone** | The gateway downloads each photo and serves it itself, because many image hosts refuse the app's requests |
| **Ready to show** | The photo appears in the app and saves to your camera roll, then Whispr tells you it's there |

### 🚨 Panic button

| Feature | Description |
|---|---|
| **Fake incoming call** | Tap **Panic** and your phone rings out loud with a call from whoever you choose |
| **Time to pocket it** | Ring right away, or after 5 or 10 seconds |
| **Two call screens** | Whispr's own full-screen call, or the real iOS call screen |
| **Picks back up** | Listening pauses during the call and resumes when it ends |

### 🔍 Built for the stage

- **Demo fallback:** buttons in Settings play the other person's line if live transcription fails
- **Stays connected:** the app reconnects by itself and keeps the screen awake while listening
- **Big text:** every whisper is also shown large on screen, so judges can see it if the audio fails
- **Tested:** 56 brain tests and 21 gateway tests

---

## 🛠️ Tech Stack

**iPhone app**

![SwiftUI](https://img.shields.io/badge/SwiftUI-F05138?style=for-the-badge&logo=swift&logoColor=white)
![CallKit](https://img.shields.io/badge/CallKit-000000?style=for-the-badge&logo=apple&logoColor=white)

**Audio gateway**

![Node.js](https://img.shields.io/badge/Node.js-339933?style=for-the-badge&logo=nodedotjs&logoColor=white)
![TypeScript](https://img.shields.io/badge/TypeScript-3178C6?style=for-the-badge&logo=typescript&logoColor=white)
![ElevenLabs](https://img.shields.io/badge/ElevenLabs_Scribe_+_Flash-000000?style=for-the-badge&logo=elevenlabs&logoColor=white)

**Brain**

![Python](https://img.shields.io/badge/Python-3776AB?style=for-the-badge&logo=python&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-009688?style=for-the-badge&logo=fastapi&logoColor=white)
![Jev](https://img.shields.io/badge/Jev_by_TypeSafe_AI-333333?style=for-the-badge)
![Claude](https://img.shields.io/badge/Claude_Haiku_5.5-D97757?style=for-the-badge&logo=anthropic&logoColor=white)
![Brave Search](https://img.shields.io/badge/Brave_Search-FB542B?style=for-the-badge&logo=brave&logoColor=white)

**Hosting**

![Render](https://img.shields.io/badge/Render-000000?style=for-the-badge&logo=render&logoColor=white)

### How it works

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

---

## ⚡ Quick Start

### Backend

```bash
git clone https://github.com/JulianCruzet/whispr.git
cd whispr/backend
cp .env.example .env     # fill in the keys you have
./scripts/dev.sh         # brain on :8000 + gateway on :8787 (Ctrl+C stops both)
```

The first run sets up a Python venv and `npm install`. Details on the brain, its tests and its message format are in [backend/README.md](backend/README.md).

| Key | Where to get it |
|---|---|
| `ELEVENLABS_API_KEY` | ElevenLabs Discord → coupon-codes → LarpHacks coupon |
| `JEV_API_KEY` | console.typesafe.ai |
| `ANTHROPIC_API_KEY` | console.anthropic.com |
| `BRAVE_SEARCH_API_KEY` | brave.com/search/api (photo search; without it the cached photo is used) |

Run the tests from `backend/`:

```bash
npm test                     # gateway
.venv/bin/python -m pytest   # brain
```

Test without talking, also from `backend/`:

```bash
npx tsx scripts/fake-phone.ts "wait, you saw Laufey live?"            # typed line as "them"
npx tsx scripts/fake-phone.ts --calibrate --wav conversation.wav       # 16 kHz mono WAV, first line = you
curl -X POST localhost:8000/transcript -H 'content-type: application/json' \
  -d '{"text":"wait, you saw Laufey live?","speaker":"them"}'          # brain only
```

### iOS app

Needs Xcode 26+. The project is generated from `ios/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd ios && xcodegen && open Whispr.xcodeproj
```

Re-run `xcodegen` after adding or removing Swift files. In Xcode, pick your team under Signing & Capabilities, plug in your iPhone and hit Run. In the app's settings, set the backend URL to `ws://<laptop-ip>:8787/ws` (same Wi-Fi), or the Render URL (`wss://.../ws`).

---

## 📁 Project Structure

```
ios/Whispr/
  Audio/                     mic capture, headphone playback, saving photos
  Net/                       WebSocket client and message types
  Panic/                     fake call screen, CallKit and ringtone
  Views/                     main screen, settings and theme
backend/
  src/                       audio gateway (Node)
    ears/                    ElevenLabs Scribe and voiceprints
    voice/                   ElevenLabs Flash TTS
    brainLink.ts             connection to the brain
    media.ts                 serves proof photos to the phone
    session.ts               one connected phone
  app/                       brain (Python)
    jev.py                   decisions
    whisper.py  prompts.py   the line to say
    personas.py              who the wearer is playing
    photo.py                 photo search and fallback
    session.py               when to whisper and when to find a photo
  test/  tests/              gateway tests, brain tests
docs/                        demo runbook, protocol, project breakdown
render.yaml                  the two Render services
```

---

## 🤖 AI Usage

- **Building it:** we used Claude to help write the code.
- **Inside the app:** Jev makes the fast decisions, Claude Haiku 5.5 writes the lines and search queries, and ElevenLabs handles speech-to-text and the voice.

---

## ⚠️ Disclaimer

Whispr is a lighthearted improv game for playing with friends. Whispered details are made up, and proof photos come from the web and belong to their owners. Not affiliated with Laufey or any artist, venue or brand mentioned.

## 👥 Team

Built at LarpHacks 2026 by [Ali Shamsi](https://github.com/shambo2), [Julian Cruzet](https://github.com/JulianCruzet) and [Kirsten Sotelo](https://github.com/KirstenSotelo).
