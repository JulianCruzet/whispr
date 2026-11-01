# Demo runbook

How to get Whispr running for the judges, and what to do when something breaks on stage. The demo story itself is in [project-breakdown.md](project-breakdown.md).

## 30 minutes before

**Laptop** (runs the backend, so keep it plugged in with the lid open):

1. `cd backend && ./scripts/dev.sh`. It starts the brain (:8000) and the audio gateway (:8787).
2. Check both are up:
   - `curl localhost:8000/health` → `anthropic_key` and `jev_key` are `true`
   - `curl localhost:8787/health` → `elevenlabs` is `true`
3. Give the phone a way in, using one of these:
   - **Render** (if deployed): use `wss://<gateway>.onrender.com/ws`.
   - **Tunnel**: `cloudflared tunnel --url http://localhost:8787` and copy the `https://….trycloudflare.com` it prints. The address changes every time the tunnel restarts.
4. Run `cd backend && npm test && .venv/bin/python -m pytest` if anything changed since the last run.

**iPhone:**

1. Headphones connected (AirPods, XM5s…). Volume up.
2. Open Whispr → ⚙️ Settings:
   - **Backend**: `wss://<tunnel or Render host>/ws` → **Reconnect**. The dot at the top left turns **green**.
   - **Listen with**: *Headphones mic*. Switch to *iPhone mic* if the headphones don't pick up the other person.
   - **Persona** (if the picker is in your build): *fan* for the Laufey demo.
   - **Panic button**: caller name and ring delay.
3. **Start listening**, then check the line above the button says your headphones for both *Mic* and *Voice*. If it says *iPhone earpiece ⚠️* or *Speaker*, reconnect the headphones.
4. Tap **Calibrate my voice** and say one normal sentence. **Don't skip this.** Without it the app can mistake your lines for theirs and whisper at the wrong time.
5. Smoke test: ⚙️ → Test → *Fake: "Wait, you saw Laufey live?"*. You should hear a whisper within about 2 s.

## During the demo

| Step | What you do | What happens |
|---|---|---|
| 1 | Teammate asks "Wait, you saw her live? Which show?" | Their line shows as **THEM**; a whisper plays in about 1–2 s |
| 2 | Say the whispered line | Your line shows as **YOU**; no whisper |
| 3 | They ask for proof | Photo task runs, then "Photo's on your phone"; the photo shows in the app and saves to Photos |
| 4 | They push too hard | Tap **Panic**: the phone rings out loud with a fake call. Say "sorry, I have to take this" |
| 5 | Accept or Decline | The call screen closes and listening resumes on its own |

## If something breaks

| Symptom | Fix |
|---|---|
| Red dot (disconnected) | The app retries on its own every few seconds. If it stays red, check `dev.sh` is still running and the backend URL in Settings matches the current tunnel address |
| Error "Brain offline" | The Python brain isn't running: restart `./scripts/dev.sh` |
| Their words don't appear | Settings → Listen with → **iPhone mic** (keep the phone between you), then recalibrate |
| Whispers on your own lines | Tap **Calibrate my voice** again, speaking at your normal volume |
| Whisper text shows but no sound | Check the route line above the button; reconnect the headphones, then Stop → Start listening. If **Last error** in Settings mentions ElevenLabs, check your credits |
| No photo | Without a search key the cached photo is used; make sure `backend/assets/fallback.jpg` or `FALLBACK_PHOTO_URL` is set |
| Live transcription fails mid-demo | Use ⚙️ → Test buttons to fake the other person's line. The whisper and voice still work |
| Panic doesn't ring out loud | Turn the volume up. The ringtone plays on the speaker even on silent |

## Reinstalling the app on the iPhone

Plug the phone into the Mac, unlock it, then from `ios/`:

```bash
xcodegen
xcodebuild -project Whispr.xcodeproj -scheme Whispr -destination 'platform=iOS,name=<your iPhone name>' -derivedDataPath build -allowProvisioningUpdates WHISPR_BACKEND_URL='wss://<host>/ws' build
xcrun devicectl device install app --device <device id from `xcrun devicectl list devices`> build/Build/Products/Debug-iphoneos/Whispr.app
```

`WHISPR_BACKEND_URL` sets the default address for a fresh install. You can always change it in Settings.
