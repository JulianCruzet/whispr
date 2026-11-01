# Roxy backend

Takes transcript lines from the app and decides whether to coach the wearer. Jev makes the decisions, Claude Haiku 5.5 writes the whisper line, and a background task finds the proof photo.

The audio gateway (`src/`, Node) owns Scribe, TTS and the phone connection: it sends this service one message per finished line and speaks the whispers it gets back. This service only sends text and image URLs. Run both with `./scripts/dev.sh`.

## Run it

From `backend/`:

```powershell
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements-dev.txt
copy .env.example .env   # then fill in the keys
.venv\Scripts\python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Check `GET /health` to see which keys and files the server can find.

Run the tests with `.venv\Scripts\python -m pytest`. They use mock transports and need no keys.

Set `FALLBACK_PHOTO_URL` or add a cached photo at `backend/assets/fallback.jpg`. Without either, a failed or slow search ends in `task_done` with `ok: false` and no photo.

## Deploy on Render

There are two web services, both with root directory `backend`. [`render.yaml`](../render.yaml) has the same settings.

**Brain (`whispr-brain`)**

- **Build command:** `pip install -r requirements.txt`
- **Start command:** `uvicorn app.main:app --host 0.0.0.0 --port $PORT`
- **Environment:** `ANTHROPIC_API_KEY`, `JEV_API_KEY`, `BRAVE_SEARCH_API_KEY`, `FALLBACK_PHOTO_URL`, `APP_SHARED_TOKEN`. `PUBLIC_BASE_URL` isn't needed because Render sets `RENDER_EXTERNAL_URL`.

**Audio gateway (`whispr`)**

- **Build command:** `npm ci --include=dev && npm run build`
- **Start command:** `npm start`
- **Environment:** `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `APP_SHARED_TOKEN` (same value as the brain) and `BRAIN_URL` (`wss://<brain host>/ws`).

The phone connects to the gateway at `wss://<gateway host>/ws`. Free services sleep when idle and can take 50 seconds or more to wake, so open both `/health` pages before a demo.

## API for the app

Connect to `WS /ws?session_id=<any id>`. If `APP_SHARED_TOKEN` is set, add `&token=<token>`. Screens using the same `session_id` all get the same events.

`POST /transcript?session_id=<id>&wait_tasks=true` takes the same message and returns `{ "events": [...] }`. It's for testing, so use the WebSocket in the app. Without `wait_tasks=true`, you miss the task's later events.

### App to backend

Send one message per committed Scribe line:

```json
{ "type": "transcript", "text": "Wait, you saw her live? Which show?", "speaker": "speaker_1", "is_final": true }
```

- `speaker` is optional. `"me"` or `"them"` is trusted as is, so send those if you know. Anything else, like a Scribe label, is only a hint and Jev decides.
- `is_final` defaults to `true`. Lines with `false` are ignored, so a whisper only follows a finished line.

Choose who the wearer is playing at any time. The default is `fan`, and changing persona clears the conversation so far:

```json
{ "type": "set_persona", "persona": "first_date" }
```

| Persona | Scene | Photos |
|---|---|---|
| `fan` | Into whatever the other person brings up | Search, then the cached photo |
| `interview` | Candidate in a mock interview | None |
| `first_date` | Charming on a pretend first date | Search only |
| `car_salesman` | Over-the-top used car sales sketch | Search only |

The backend replies with `{ "type": "persona", "persona": "first_date" }`, or an `error` event if it doesn't know the persona. To test one with `POST /transcript`, add `&persona=first_date`. Personas are defined in [app/personas.py](app/personas.py).

### Backend to app

**`transcript`** echoes each line with Jev's read of it. Use it for the live transcript and the cover-blown meter. `cover_blown_risk` runs from 0 to 1, or is `null` if Jev failed.

```json
{ "type": "transcript", "text": "...", "who_spoke": "them", "cover_blown_risk": 0.5 }
```

**`whisper`** is a line to speak through TTS and show as big text. `reason` is `"reply"` or `"task_done"`, and `cover_blown_risk` is `null` on `"task_done"`.

```json
{ "type": "whisper", "id": "ab12", "text": "Say the Toronto show at Scotiabank Arena.", "reason": "reply", "cover_blown_risk": 0.5 }
```

**`task_started`** means the photo search has begun.

```json
{ "type": "task_started", "task_id": "cd34", "task": "find_photo" }
```

**`task_done`** carries the photo to display. The `whisper` with reason `"task_done"` follows right after it.

```json
{ "type": "task_done", "task_id": "cd34", "task": "find_photo", "ok": true, "image_url": "https://...", "title": "...", "query": "...", "used_fallback": false }
```

If `ok` is `false`, the other photo fields are missing and no whisper follows.

**`error`** means a message was malformed. The connection stays open.

```json
{ "type": "error", "detail": [ ] }
```

### Notes for the app

- **Queue whispers:** `task_done` can arrive while the first whisper is still playing, so don't play them over each other.
- **Handle a bad `image_url`:** search photos are hosted on other sites. The backend checks that the URL loads from the server, but a site could still block the phone.

## When it whispers

The wearer gets a `reply` whisper when all of these are true:

- The line came from `them`.
- Jev's `should_whisper` is at least 0.7.
- At least 5 seconds have passed since the last whisper.

A photo task starts when the line came from `them` and Jev picks `find_photo` with at least 0.6 probability. It runs at most once every 30 seconds. Search has 5 seconds before the cached photo is used.

These values are in [app/config.py](app/config.py), and each can be overridden with an environment variable. The cover story is in [app/prompts.py](app/prompts.py).

Jev can also pick `look_up_fact`, but it's a stretch goal and nothing runs for it yet.
