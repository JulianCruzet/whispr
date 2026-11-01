# Project Roxy (working title): LarpHacks 2026

> Like the Kingsman scene where Roxy feeds Eggsy the right answers through his earpiece.
> An AI listens to your conversation through your AirPods and whispers what to say next, in real time.
> When you're bluffing, it goes and gets the proof, then tells you it's on your phone.

**Event:** LarpHacks, Sun Nov 1, Bahen Centre, UofT
**Hacking:** 11:00 AM to **6:00 PM hard submission cutoff**
**Demos:** 6:30–8:00 PM, with a **2-minute demo + 2-minute Q&A**
**Team:** 3 people, all vibe coding with Claude

---

## 1. The demo moment

You're bluffing being a Laufey fan with a *real* Laufey fan.

1. They say: "Wait, you saw her live? Which show?"
2. Your AirPod whispers: *"Say the Toronto show at Scotiabank Arena. Say 'From The Start' live wrecked you."*
3. In the background, the agent finds a photo of the Laufey concert at Scotiabank Arena and sends it to your phone.
4. A few seconds later your AirPod whispers: *"Photo's on your phone. Show them the shot from the floor."*
5. You pull out your iPhone and show the proof.
6. They push harder with a question you can't bluff, so you press **Panic**.
7. A fake incoming call appears on your phone. You say "Sorry, I have to take this" and walk away.

---

## 2. How it works

```
iPhone app
  ├─ Mic (AirPods or the phone's own mic) → ElevenLabs Scribe (realtime speech-to-text)
  ├─ sends transcript → Backend (hosted on Render)
  │     ├─ Jev (TypeSafe AI): fast decisions
  │     │     • should_whisper?  (noul: is a reply needed right now?)
  │     │     • who_spoke?       (choice: me / them)
  │     │     • launch_task?     (choice: none / find_photo / look_up_fact)
  │     │     • cover_blown_risk (score: how close am I to getting caught)
  │     ├─ Claude Haiku 5.5: writes the actual whisper line (short, ≤15 words)
  │     └─ Background photo task:
  │           image search → pick the best photo → email it via Agentboxd
  │           (+ return the image URL to the app)
  ├─ ElevenLabs Flash TTS → whisper played in your AirPods
  ├─ Shows the photo / saves it to Photos → "Photo's ready."
  └─ Panic button → fake incoming call on screen
```

**Division of labour:**
- **Jev** is the gatekeeper and router. It's very fast and cheap, so it runs on every transcript chunk and decides *whether* and *what* to do.
- **Haiku 5.5** only writes the words. That keeps it fast and cheap.
- **ElevenLabs** is the ears (Scribe) and the voice (Flash TTS).
- **Agentboxd** gives the agent an email inbox to deliver proof to your phone.

**Target latency:** about 1–1.5 seconds from them finishing a sentence to you hearing the cue.

**Panic button:** When the bluff falls apart, you press Panic and a fake incoming call appears on your phone so you can "take the call" and escape. The main goal is showing the call on screen. The fake call **cuts off the mic and whispers** while it's up, and we're accepting that for now.

---

## 3. Tech stack

| Piece | Choice | Notes |
|---|---|---|
| Speech-to-text | **ElevenLabs Scribe** (realtime) | Streams audio over a WebSocket and returns a live transcript; has speaker labels |
| Decisions | **Jev** by TypeSafe AI | `POST https://api.typesafe.ai/v1/systemone`, model `jev-latest`; 70–500 ms (vendor figures). Check the details at docs.typesafe.ai |
| Whisper line | **Claude Haiku 5.5** (`claude-haiku-5-5`) | $0.10 / $0.50 per 1M tokens, about $0.0002 per whisper. Use low effort, thinking off |
| Text-to-speech | **ElevenLabs Flash** | Their lowest-latency voice model; pick a calm, quiet "Roxy" voice |
| Photo search | SerpAPI or Brave Search image API | Found photo, with a **cached fallback photo** in case search fails or takes >5 s |
| Photo delivery | **Agentboxd** | The agent emails the photo from its own inbox to your phone |
| Backend hosting | **Render** | Also counts for the Render track |
| iPhone app | **Native SwiftUI (Xcode)**, with a **web app in Safari as fallback** | Native gives reliable mic routing and saving to Photos |
| Panic button | **iOS CallKit** fake call, with a **Call GIF + vibration as fallback** | Runs in the app, no backend needed. CallKit cuts off audio during the call (accepted for now) |

---

## 4. Prize tracks we're going for

| Track | How we qualify | Prize |
|---|---|---|
| **Overall** | Judged out of 30 (see below) | 1st: $300 + $297 ElevenLabs Pro credits/person + $300 Featherless credits |
| **ElevenLabs** | Scribe + TTS are the core of the product | **$897 in Max credits per person** |
| **Agentboxd** | The agent emails the proof photo from its inbox | 3 months of the Team plan ($360) |
| **Render** | Backend deployed on Render, shown live | $500 / $300 / $100 in credits |

**Judging, 30 points (6 criteria × 5):** Working Product, Usefulness, **Theme Alignment** (the theme is revealed at opening, so make sure we tie into it), Creativity, Ease of Use, Demo.

---

## 5. Team split (3 people)

| Person | Owns | Done when |
|---|---|---|
| **A: Ears & Voice (iPhone)** | iPhone app: mic capture, Scribe streaming, TTS playback to AirPods, photo display/save, Panic button | Talk near the phone, the transcript appears, and a whisper plays in the AirPods. Pressing Panic shows the fake call |
| **B: Brain & Tasks (backend)** | Jev gates, Haiku whisper prompt, photo task (search + Agentboxd email), API for the app | A transcript snippet goes in, a whisper line comes out, and the photo is emailed when needed |
| **C: Face & Stage** | Render deploy, UI polish (live transcript, suggestion text, cover-blown meter, task status), demo script + pitch, submission form | Deployed URL works, the 2-min script is rehearsed, and the submission is in |

**Shared contract (agree on this early):** simple JSON events between app and backend:
`{ type: "transcript" | "whisper" | "task_started" | "task_done", ... }`

---

## 6. Timeline (today)

| Time | Milestone |
|---|---|
| **11:30** | Keys in `.env`, repo set up, Xcode downloading, roles locked |
| **11:45** | **Mic test** (see Risks): can it hear the *other* person? |
| **12:00–1:30** | Each person builds their piece separately (mock the other pieces) |
| **1:30** | **First end-to-end**: speak → transcript → whisper heard |
| **2:30–3:30** | Google workshop (optional; someone keeps building) |
| **3:30** | Photo task working end to end (search → email → "photo's ready") |
| **4:00** | Panic button working (press Panic → fake call on screen) |
| **4:30** | Feature freeze. Polish the UI, deploy to Render, fix bugs only |
| **5:00** | Rehearse the demo 3+ times with the "true fan" teammate |
| **5:45** | Submit. **Don't wait until 5:59** |
| **6:00** | Hard cutoff |

---

## 7. Risks & fallbacks

| Risk | Fallback |
|---|---|
| **AirPods mic filters out the other person's voice** (AirPods are tuned to the wearer's voice) | Try Mic Mode → Wide Spectrum in Control Center. If that's still bad, **use the iPhone's own mic** (phone on the table or in a pocket) with output still in the AirPods. Native iOS can force this |
| **Xcode not ready in time** (1–2 hr install, macOS update first) | **Web app in iPhone Safari** using the same backend. Save the photo via the share sheet or long-press |
| Image search fails / is slow on venue Wi-Fi | **Cached Scotiabank Arena photo** sent if search takes >5 s |
| Whispers fire too often / talk over you | Only whisper after a pause from *them*, when Jev's `should_whisper` is high; max one whisper every ~5 s |
| Whisper is too long to be useful | Hard cap in the prompt: ≤15 words, one line, no preamble |
| Live demo audio is flaky | Also show the whisper as **big text on screen**, so judges see it even if the audio fails |
| Speaker confusion (it coaches you on your own words) | Jev `who_spoke` + Scribe speaker labels + only trigger after their turn |
| Fake call (CallKit) doesn't work, or we're on the web app | **Full-screen Call GIF + vibration.** Safari can't vibrate, so the web app gets the GIF only |

---

## 8. Setup checklist

- [x] Freed disk space (23 GB → 58 GB free)
- [ ] macOS update (in progress)
- [ ] Xcode installed (Mac App Store, opened, click **Get**)
- [ ] iPhone **Developer Mode** on (Settings → Privacy & Security → Developer Mode)
- [ ] Cable to connect the iPhone to the Mac
- [ ] **Jev API key** (console.typesafe.ai)
- [ ] **ElevenLabs coupon** (ElevenLabs Discord → coupon-codes → Start Redemption → LarpHacks, use your Luma email)
- [ ] **Anthropic API key** with a few dollars of credit (Haiku 5.5)
- [ ] **Agentboxd** account + redeem `LARPHACKS-2026` → create API key + inbox
- [ ] Image search API key (SerpAPI or Brave)
- [ ] Render account
- [ ] All keys go in a `.env` file. **Never paste keys in chat or commit them**
- [ ] Real project folder + git repo

---

## 9. Still to decide

- **Project name** + team name (for the submission)
- **Theme tie-in** once the theme is known
- Who plays the "true Laufey fan" in the demo, and their 4–5 scripted lines
- Mic setup: AirPods mic vs. iPhone mic (decided by the 11:45 test)
- Native vs. web: decided by whether Xcode is ready
- Stretch goals (only if ahead of schedule): "cover blown" meter, more task types (fact lookup), a mission-control screen, multiple personas (interview, first date, car salesman)
