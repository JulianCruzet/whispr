# Phone ⇄ backend protocol

One WebSocket per phone at `/ws`. Source of truth: `backend/src/protocol.ts` (mirrored in `ios/Whispr/Net/Protocol.swift`).

## Phone → backend

| Frame | Content |
|---|---|
| binary | Mic audio: PCM signed 16-bit little-endian, mono, **16 kHz**, ~100 ms per frame |
| text | `{"type":"hello","device":"iphone","sampleRate":16000,"deviceId":"..."}` on connect. `deviceId` (stable per phone) lets a reconnecting phone keep its voice calibration |
| text | `{"type":"debug_turn","text":"...","speaker":"them"}`: pretend someone said `text` (skips speech-to-text). Testing and demo fallback |
| text | `{"type":"calibrate","who":"me"}` or `"who":"them"`: the next lines spoken are that person's; the backend listens across up to 4 lines until the wearer has talked ~6 s or the other person ~5 s (from Scribe's word times), and takes a voice sample. `who` defaults to `me`. `"seconds":15` asks for a longer sample (up to 30 s; the app's Settings uses 15 for a demo) |
| text | `{"type":"clear_calibration"}`: forget both voice samples, calibrated or learnt, for this phone |
| text | `{"type":"cancel_calibration"}`: stop a calibration step in progress, keeping nothing. Nothing said during calibration ever reaches the brain or the conversation |
| text | `{"type":"set_persona","persona":"first_date"}`: who the wearer is playing: `fan` (default), `interview`, `first_date` or `car_salesman`. Send it on every `ready` and when it changes. Changing it clears the conversation so far |
| text | `{"type":"set_turns","alternate":true}`: strict turn-taking for a rigged demo. Lines are labelled `me`, `them`, `me`... in order, starting with the wearer, whatever the voices sound like; a line holding both voices counts as two turns, and a line that's only filler ("mm", "uh") or 12 dB quieter than the recent turns is skipped as background without using up a turn. Scribe then ends a line after 0.7 s of silence instead of 0.4 s. Send it on every `ready` |
| text | `{"type":"flip_turn"}`: turn-taking slipped, swap who is next |
| text | `{"type":"audio_state","route":"Mic: AirPods · Voice: AirPods","engine":true,"listening":true}`: sent as each whisper starts playing, so the gateway log shows where it played |
| text | `{"type":"ping"}` |

## Backend → phone

| Frame | Content |
|---|---|
| text | `ready` `{sessionId, integrations}`: sent on connect; `integrations` says which services are live vs. mock |
| text | `transcript` `{id, text, final, speaker}`: `final:false` is a live partial (id `"partial"`), `final:true` is a finished turn. `speaker` is `me` / `them` / `unknown` (see below) |
| text | `whisper` `{id, text, spoken, reason}`: `spoken` is the short cue said in the ear (show it big) and `text` the full line (show it under the cue); `reason` `reply` is the line to say; `photo_ready` means the proof photo just landed (show it with the photo, and keep the line) |
| text | `whisper_audio_start` `{id, sampleRate}` → binary frames → `whisper_audio_end` `{id}`: the spoken whisper, PCM16 mono at `sampleRate` (24 kHz). The ear gets a short cue of the line (3 to 7 words, no "Say"), not the full `text` on the screen |
| text | `risk` `{score}`: 0..1, how close you are to getting caught |
| text | `task_started` `{id, kind, label}`: e.g. finding a photo |
| text | `task_done` `{id, kind, ok, imageUrl?, caption?}`: `imageUrl` normally points at this gateway (`/media/<id>`), which downloads the photo so the phone never hits a host that blocks it. If the gateway couldn't fetch it, it's the original address |
| text | `calibrating` `{who, seconds, target}`: calibration progress, seconds talked so far out of `target`. Sent live (every 250 ms) while they talk, and again when each line is finished |
| text | `calibrated` `{who, ok, reason?}`: the calibration finished. `ok:false` comes with `reason` `too_short` (under 1.5 s of speech in 4 lines) or `sounds_like_you` (the other person's sample was really the wearer). Also sent on connect for samples a returning `deviceId` already has |
| text | `turn` `{next}`: with turn-taking on, who the next line will be labelled as (`null` when it's off) |
| text | `error` `{message}`, `pong` |

## When is a turn finished?

- Normally when ElevenLabs Scribe hears ~0.6 s of silence.
- **Questions go out early:** if the live transcript ends in `?` and doesn't change for 300 ms, it's sent as a finished turn right away. Anything said after it in the same breath follows as its own turn.

## Who said it?

ElevenLabs Scribe realtime doesn't label speakers, so the gateway takes a **voiceprint** of every line: its average timbre (12 MFCCs), median pitch and loudness (`backend/src/ears/voiceprint.ts`).

- **Calibrate both voices** (`calibrate` `who:"me"`, then `who:"them"`, a sentence or two each). Each line is then placed between the two samples (`speakers.ts`): near the wearer's → `me`, near theirs → `them`, in between → `unknown`. Loudness doesn't decide it, so it works with both people equally loud.
- **While sampling the other person,** lines that might be the wearer (prompting them, say) are left out of their sample and go through as `me`, at most two.
- **A line holding both voices** (a quick back-and-forth Scribe committed as one) is split at the word where the voice changes, and sent as two turns.
- **Only the wearer calibrated:** each line is scored by how far it is from the wearer's voice: close → `me`, clearly another voice → `them`, in between → `unknown`. It leans to `unknown` rather than risk calling the wearer `them`. A line with no voiceprint falls back to loudness (within 8 dB of the wearer is `me`).
- **Not calibrated, or `unknown`:** the brain's Jev decides from the words. Lines Jev is at least 80% sure about teach the gateway that voice, so after a few lines each, voices are placed by sound even with no calibration.
- **Background:** if Jev is at least 60% sure an unplaced line isn't part of this conversation (a TV, a passer-by), it's dropped: no whisper, and it's kept out of the story. Lines that are only Scribe noise tags (`(background noise)`, `[music]`) never reach the brain.
- Lines from `me` never get a whisper.

`npx tsx scripts/eval-speakers.ts <dir> <VoiceA> <VoiceB>` scores two recorded voices at equal loudness (see the script for the file layout).

## Dashboard

`/ws/dashboard` receives a copy of every JSON event above (no audio), for a mission-control screen on a laptop or projector.
