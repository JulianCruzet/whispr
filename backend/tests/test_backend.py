import asyncio
import io
import json
import time

import anthropic
import httpx
import httpx2
import pytest
from fastapi.testclient import TestClient
from PIL import Image

import app.photo as photo_module
from app.config import Settings
from app.events import TranscriptIn
from app.main import create_app
from app.personas import PERSONAS
from app.prompts import PHOTO_COMING_NOTE, photo_query_system, whisper_system
from app.session import PHOTO_READY_SPOKEN, PHOTO_READY_WHISPER, Deps, Session
from app.whisper import MAX_SPOKEN_WORDS, cap_words, clean_cue, clean_line, write_whisper, drop_trailing_instruction

IMAGE_URL = "https://img.example/laufey.jpg"


def jev_response(should_whisper=0.95, who="them", task="none", task_p=0.9, risk=1.5, who_p=0.9):
    return {
        "answers": {
            "should_whisper": {"type": "noul", "noul": should_whisper},
            "who_spoke": {"type": "choice", "choice": who, "probabilities": {who: who_p}},
            "launch_task": {"type": "choice", "choice": task, "probabilities": {task: task_p}},
            "cover_blown_risk": {"type": "score", "score": risk},
        }
    }


class Backend:
    """Real SDK clients on mock transports, so the requests we build are checked too."""

    def __init__(self, whisper_text="Say the Toronto show.", **settings):
        self.jev = jev_response()
        self.whisper_text = whisper_text
        self.stop_reason = "end_turn"
        self.fail_search = False
        self.search_results = [{"title": "Laufey live", "properties": {"url": IMAGE_URL}}]
        # Image bodies by URL; anything else gets a tiny unsized "image".
        self.images: dict[str, bytes] = {}
        # Jev's pick for "best_photo" as option -> probability, or None to fail that call.
        self.photo_rank: dict[str, float] | None = None
        # What Haiku says when it looks at an image, by image URL ("yes" if missing).
        self.looks: dict[str, str] = {}
        # Seconds each answer takes: by host for HTTP calls, by image URL for Haiku's looks.
        self.delays: dict[str, float] = {}
        self.claude_requests = []
        self.jev_requests = []

        self.deps = Deps(
            settings=Settings(
                _env_file=None,
                anthropic_api_key="test",
                jev_api_key="test",
                brave_search_api_key="test",
                public_base_url="https://whispr.example",
                **settings,
            ),
            http=httpx.AsyncClient(transport=httpx.MockTransport(self._http)),
            claude=anthropic.AsyncAnthropic(
                api_key="test",
                max_retries=0,
                http_client=anthropic.DefaultAsyncHttpxClient(
                    transport=httpx2.MockTransport(self._claude)
                ),
            ),
        )

    async def _http(self, request: httpx.Request) -> httpx.Response:
        await asyncio.sleep(self.delays.get(request.url.host, 0))
        if request.url.host == "api.typesafe.ai":
            body = json.loads(request.content)
            self.jev_requests.append(body)
            if "best_photo" in body["questions"]:
                if self.photo_rank is None:
                    return httpx.Response(500)
                best = max(self.photo_rank, key=self.photo_rank.get)
                return httpx.Response(
                    200,
                    json={"answers": {"best_photo": {"type": "choice", "choice": best, "probabilities": self.photo_rank}}},
                )
            return httpx.Response(200, json=self.jev)
        if request.url.host == "api.search.brave.com":
            if self.fail_search:
                return httpx.Response(500)
            return httpx.Response(200, json={"results": self.search_results})
        body = self.images.get(str(request.url), b"jpg")
        return httpx.Response(200, headers={"content-type": "image/jpeg"}, content=body)

    async def _claude(self, request: httpx2.Request) -> httpx2.Response:
        body = json.loads(request.content)
        self.claude_requests.append(body)
        content = body["messages"][0]["content"]
        if isinstance(content, list) and content[0]["type"] == "image":
            await asyncio.sleep(self.delays.get(content[0]["source"]["url"], 0))
            answer = self.looks.get(content[0]["source"]["url"], "yes")
            return httpx2.Response(
                200,
                json={
                    "id": "msg_look",
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-haiku-5-5",
                    "content": [{"type": "text", "text": answer}],
                    "stop_reason": "end_turn",
                    "stop_sequence": None,
                    "usage": {"input_tokens": 10, "output_tokens": 1},
                },
            )
        return httpx2.Response(
            200,
            json={
                "id": "msg_1",
                "type": "message",
                "role": "assistant",
                "model": "claude-haiku-5-5",
                "content": [{"type": "text", "text": self.whisper_text}],
                "stop_reason": self.stop_reason,
                "stop_sequence": None,
                "usage": {"input_tokens": 10, "output_tokens": 5},
            },
        )


def run_line(backend: Backend, *lines: TranscriptIn) -> list[dict]:
    async def go() -> list[dict]:
        session = Session(backend.deps)
        events: list[dict] = []

        async def collect(event: dict) -> None:
            events.append(event)

        session.listeners.add(collect)
        for line in lines:
            await session.handle_transcript(line)
        while session.tasks:
            await asyncio.gather(*session.tasks)
        return events

    return asyncio.run(go())


def types(events: list[dict]) -> list[str]:
    return [event["type"] for event in events]


def line(text="Wait, you saw her live? Which show?", **fields) -> TranscriptIn:
    return TranscriptIn(text=text, **fields)


def test_their_question_gets_a_whisper():
    backend = Backend()
    events = run_line(backend, line())

    assert types(events) == ["transcript", "whisper"]
    assert events[0]["who_spoke"] == "them"
    assert events[0]["cover_blown_risk"] == pytest.approx(0.5)
    assert events[1]["text"] == "Say the Toronto show."
    assert events[1]["reason"] == "reply"
    # A one-line reply: the ear gets the whole line.
    assert events[1]["spoken"] == "Say the Toronto show."


def test_the_ear_gets_a_short_cue_and_the_screen_the_full_line():
    backend = Backend(
        whisper_text="Say the Toronto crowd was lit and God's Plan was the high point.\n"
        "Crowd was lit, God's Plan."
    )
    events = run_line(backend, line())

    assert events[1]["text"] == "Say the Toronto crowd was lit and God's Plan was the high point."
    assert events[1]["spoken"] == "Crowd was lit, God's Plan."
    system = backend.claude_requests[0]["system"]
    assert "For their ear" in system and "3 to 6 words" in system


@pytest.mark.parametrize(
    "raw, cue",
    [
        ("Crowd was lit, God's Plan", "Crowd was lit, God's Plan"),
        ("2. Ear: Say that the crowd was lit", "The crowd was lit"),
        ('"Massey Hall, 2023"', "Massey Hall, 2023"),
        ("2.5 boxer, never blew", "2.5 boxer, never blew"),
    ],
)
def test_clean_cue_strips_labels_quotes_and_say(raw, cue):
    assert clean_cue(raw) == cue


def test_a_long_cue_is_cut_on_the_last_clause_that_fits():
    backend = Backend(
        whisper_text="Say the Toronto show.\nCrowd was lit, God's Plan closed it, then Hotline Bling encore"
    )
    events = run_line(backend, line())

    assert events[1]["spoken"] == "Crowd was lit, God's Plan closed it"
    assert len(events[1]["spoken"].split()) <= MAX_SPOKEN_WORDS


def test_whisper_request_matches_the_spec():
    backend = Backend()
    run_line(backend, line())

    request = backend.claude_requests[0]
    assert request["model"] == "claude-haiku-5-5"
    assert request["thinking"] == {"type": "disabled"}
    assert request["output_config"] == {"effort": "low"}
    assert "Which show?" in request["messages"][0]["content"]


def test_jev_request_asks_all_four_questions_about_the_conversation():
    backend = Backend()
    run_line(backend, line())

    request = backend.jev_requests[0]
    assert request["model"] == "jev-latest"
    assert "Which show?" in request["state"]
    assert set(request["questions"]) == {
        "should_whisper",
        "who_spoke",
        "launch_task",
        "cover_blown_risk",
    }


def test_never_coaches_on_the_wearers_own_words():
    backend = Backend()
    backend.jev = jev_response(who="me")
    events = run_line(backend, line("I saw her in Toronto."))

    assert types(events) == ["transcript"]
    assert backend.claude_requests == []


def test_wearers_claim_gets_a_photo_but_no_reply_whisper():
    backend = Backend(whisper_text="Drake Scotiabank Arena crowd")
    backend.jev = jev_response(who="me", task="find_photo")
    events = run_line(backend, line("I went to Drake's concert last night."))

    assert types(events) == ["transcript", "task_started", "task_done", "whisper"]
    assert events[-1]["reason"] == "task_done"
    # Haiku wrote the search query and looked at the photo; nothing was written back at the wearer.
    assert "image search query" in backend.claude_requests[0]["system"]
    assert all(
        "image search query" in r.get("system", "") or r["messages"][0]["content"][0]["type"] == "image"
        for r in backend.claude_requests
    )


def test_explicit_speaker_overrides_jev():
    backend = Backend()
    backend.jev = jev_response(who="them")
    events = run_line(backend, line(speaker="me"))

    assert types(events) == ["transcript"]
    assert events[0]["who_spoke"] == "me"


def test_low_should_whisper_stays_quiet():
    backend = Backend()
    backend.jev = jev_response(should_whisper=0.2)

    assert types(run_line(backend, line())) == ["transcript"]


def test_cooldown_limits_whispers():
    backend = Backend()
    events = run_line(backend, line("First?"), line("Second?"))

    assert types(events).count("whisper") == 1


def test_a_background_line_is_dropped_without_a_whisper():
    backend = Backend()
    backend.jev = jev_response(who="background", who_p=0.8)
    events = run_line(backend, line("Breaking news tonight on channel five"))

    assert types(events) == ["transcript"]
    assert events[0]["who_spoke"] == "background"


def test_an_unsure_background_call_is_kept():
    backend = Backend()
    backend.jev = jev_response(who="background", who_p=0.4)
    events = run_line(backend, line())

    assert events[0]["who_spoke"] == "unknown"


def test_jev_never_drops_a_line_the_voice_already_placed():
    backend = Backend()
    backend.jev = jev_response(who="background", who_p=0.95)
    events = run_line(backend, line(speaker="them"))

    assert types(events) == ["transcript", "whisper"]
    assert events[0]["who_spoke"] == "them"


def test_jevs_confidence_goes_back_with_the_verdict():
    backend = Backend()
    backend.jev = jev_response(who="me", who_p=0.92)
    events = run_line(backend, line())

    assert events[0]["who_spoke"] == "me"
    assert events[0]["who_spoke_p"] == pytest.approx(0.92)


def test_partial_transcripts_are_ignored():
    backend = Backend()

    assert run_line(backend, line(is_final=False)) == []
    assert backend.jev_requests == []


def test_whisper_is_capped_to_one_line_of_15_words():
    backend = Backend(whisper_text='"' + " ".join(["word"] * 30) + '"\nSecond line')
    events = run_line(backend, line())

    assert events[1]["text"] == " ".join(["word"] * 15)


def test_long_whisper_ends_on_the_last_clause_that_fits():
    backend = Backend(
        whisper_text="Say your phone died before you could take any photos, "
        "and that's why you're the only one without any"
    )
    events = run_line(backend, line())

    assert events[1]["text"] == "Say your phone died before you could take any photos"


def test_whisper_knows_when_a_photo_is_coming():
    backend = Backend()
    backend.jev = jev_response(task="find_photo")
    run_line(backend, line())

    assert any(PHOTO_COMING_NOTE in r["messages"][0]["content"] for r in backend.claude_requests)


def test_whisper_does_not_mention_a_photo_otherwise():
    backend = Backend()
    run_line(backend, line())

    assert PHOTO_COMING_NOTE not in backend.claude_requests[0]["messages"][0]["content"]


def test_missing_search_key_uses_the_cached_photo_without_searching(cached_photo):
    backend = Backend()
    backend.deps.settings.brave_search_api_key = ""
    backend.fail_search = True
    done = done_event(backend)

    assert done["ok"] is True
    assert done["used_fallback"] is True


def test_refusal_sends_no_whisper_and_frees_the_cooldown():
    backend = Backend()
    backend.stop_reason = "refusal"

    async def go():
        session = Session(backend.deps)
        await session.handle_transcript(line())
        return session.last_whisper_at

    assert asyncio.run(go()) == float("-inf")


def test_jev_failure_keeps_the_stream_alive():
    backend = Backend()
    backend.jev = {"unexpected": "shape"}
    events = run_line(backend, line("Which show?", speaker="them"))

    assert types(events) == ["transcript"]
    assert events[0]["cover_blown_risk"] is None


def test_photo_task_returns_the_image_url_and_whispers_when_ready():
    backend = Backend(whisper_text="Laufey Scotiabank Arena")
    backend.jev = jev_response(task="find_photo")
    events = run_line(backend, line())

    assert set(types(events)) == {"transcript", "task_started", "task_done", "whisper"}
    done = next(event for event in events if event["type"] == "task_done")
    assert done["ok"] is True
    assert done["image_url"] == IMAGE_URL
    assert done["used_fallback"] is False
    assert events[-1]["text"] == PHOTO_READY_WHISPER
    assert events[-1]["spoken"] == PHOTO_READY_SPOKEN
    assert events[-1]["reason"] == "task_done"


def test_photo_task_runs_once_during_its_cooldown():
    backend = Backend()
    backend.jev = jev_response(task="find_photo")
    events = run_line(backend, line("Which show?"), line("Got pics?"))

    assert types(events).count("task_started") == 1


def test_low_confidence_task_does_not_launch():
    backend = Backend()
    backend.jev = jev_response(task="find_photo", task_p=0.4)

    assert "task_started" not in types(run_line(backend, line()))


def test_look_up_fact_does_not_launch_yet():
    backend = Backend()
    backend.jev = jev_response(task="look_up_fact")

    assert "task_started" not in types(run_line(backend, line()))


@pytest.fixture
def cached_photo(tmp_path, monkeypatch):
    (tmp_path / "fallback.jpg").write_bytes(b"jpg")
    monkeypatch.setattr(photo_module, "ASSETS_DIR", tmp_path)


def done_event(backend: Backend) -> dict:
    backend.jev = jev_response(task="find_photo")
    return next(event for event in run_line(backend, line()) if event["type"] == "task_done")


def test_search_failure_uses_the_cached_photo(cached_photo):
    backend = Backend()
    backend.fail_search = True
    done = done_event(backend)

    assert done["ok"] is True
    assert done["used_fallback"] is True
    assert done["image_url"] == "https://whispr.example/assets/fallback.jpg"


def test_fallback_photo_url_takes_priority(cached_photo):
    backend = Backend(fallback_photo_url="https://cdn.example/arena.jpg")
    backend.fail_search = True
    done = done_event(backend)

    assert done["used_fallback"] is True
    assert done["image_url"] == "https://cdn.example/arena.jpg"


def test_broken_results_use_the_cached_photo(cached_photo):
    backend = Backend()
    backend.search_results = [{"properties": {"url": "http://insecure.example/a.jpg"}}]

    assert done_event(backend)["used_fallback"] is True


def test_slow_search_uses_the_cached_photo(cached_photo):
    backend = Backend(photo_deadline_s=0.01)

    async def slow(*_):
        await asyncio.sleep(1)

    backend_search = photo_module._search
    photo_module._search = slow
    try:
        assert done_event(backend)["used_fallback"] is True
    finally:
        photo_module._search = backend_search


def test_no_photo_at_all_reports_failure_without_a_whisper(tmp_path, monkeypatch):
    monkeypatch.setattr(photo_module, "ASSETS_DIR", tmp_path)
    backend = Backend()
    backend.fail_search = True
    backend.jev = jev_response(task="find_photo")
    events = run_line(backend, line())

    done = next(event for event in events if event["type"] == "task_done")
    assert done["ok"] is False
    assert PHOTO_READY_WHISPER not in [event.get("text") for event in events]


def test_write_whisper_returns_none_for_an_empty_reply():
    backend = Backend(whisper_text="   ")

    async def go():
        return await write_whisper(backend.deps.claude, backend.deps.settings, "x")

    assert asyncio.run(go()) is None


def test_post_transcript_returns_events():
    backend = Backend()
    backend.jev = jev_response(task="find_photo")
    with TestClient(create_app(backend.deps)) as client:
        response = client.post(
            "/transcript", params={"wait_tasks": True}, json={"type": "transcript", "text": "Which show?"}
        )

    assert response.status_code == 200
    assert {"transcript", "whisper", "task_started", "task_done"} == set(
        types(response.json()["events"])
    )


def test_websocket_streams_events_and_reports_bad_messages():
    backend = Backend()
    with TestClient(create_app(backend.deps)) as client:
        with client.websocket_connect("/ws") as ws:
            ws.send_text("not json")
            assert ws.receive_json()["type"] == "error"

            ws.send_json({"type": "transcript", "text": "Which show?"})
            assert ws.receive_json()["type"] == "transcript"
            assert ws.receive_json()["type"] == "whisper"


def run_with_persona(backend: Backend, persona_id: str, *lines: TranscriptIn) -> list[dict]:
    async def go() -> list[dict]:
        session = Session(backend.deps)
        assert session.set_persona(persona_id)
        events: list[dict] = []

        async def collect(event: dict) -> None:
            events.append(event)

        session.listeners.add(collect)
        for msg in lines:
            await session.handle_transcript(msg)
        while session.tasks:
            await asyncio.gather(*session.tasks)
        return events

    return asyncio.run(go())


def test_default_persona_is_the_fan():
    backend = Backend()
    run_line(backend, line())

    assert "whatever the other person brings up" in backend.claude_requests[0]["system"]
    assert "whatever the other person brings up" in backend.jev_requests[0]["state"]


@pytest.mark.parametrize("persona_id", PERSONAS)
def test_no_persona_steers_towards_a_specific_artist_or_venue(persona_id):
    persona = PERSONAS[persona_id]
    prompts = whisper_system(persona) + persona.scenario
    if persona.photo_hint:
        prompts += photo_query_system(persona)

    for word in ("laufey", "scotiabank", "from the start", "encore"):
        assert word not in prompts.lower()


@pytest.mark.parametrize("persona_id", PERSONAS)
def test_every_persona_stays_specific_to_the_conversation(persona_id):
    assert "Be specific to this conversation" in whisper_system(PERSONAS[persona_id])


@pytest.mark.parametrize("persona_id", PERSONAS)
def test_every_persona_redirects_instead_of_sounding_unsure(persona_id):
    prompt = whisper_system(PERSONAS[persona_id])

    assert "Never sound unsure" in prompt
    assert "The redirect must stay on that topic" in prompt


def test_cached_photo_has_no_hardcoded_caption(cached_photo):
    backend = Backend()
    backend.fail_search = True
    done = done_event(backend)

    assert done["used_fallback"] is True
    assert done["title"] is None


@pytest.mark.parametrize(
    "persona_id, phrase",
    [("interview", "mock interview"), ("first_date", "first date"), ("car_salesman", "used car")],
)
def test_persona_shapes_the_whisper_and_jev(persona_id, phrase):
    backend = Backend()
    run_with_persona(backend, persona_id, line("Tell me more?"))

    assert phrase in backend.claude_requests[0]["system"]
    assert phrase in backend.jev_requests[0]["state"]


def test_unknown_persona_is_rejected_and_keeps_the_current_one():
    session = Session(Backend().deps)

    assert session.set_persona("pirate") is False
    assert session.persona.id == "fan"


def test_changing_persona_clears_the_conversation():
    session = Session(Backend().deps)
    session.history.append({"speaker": "them", "text": "old scene"})

    session.set_persona("fan")
    assert len(session.history) == 1

    session.set_persona("interview")
    assert len(session.history) == 0


def test_interview_never_looks_for_a_photo():
    backend = Backend()
    backend.jev = jev_response(task="find_photo")
    events = run_with_persona(backend, "interview", line("Do you have a portfolio?"))

    assert "task_started" not in types(events)


def test_other_personas_never_get_the_laufey_photo(cached_photo):
    backend = Backend()
    backend.fail_search = True
    backend.jev = jev_response(task="find_photo")
    events = run_with_persona(backend, "first_date", line("Got pics of that place?"))

    done = next(event for event in events if event["type"] == "task_done")
    assert done["ok"] is False
    assert PHOTO_READY_WHISPER not in [event.get("text") for event in events]


def test_other_personas_still_get_searched_photos():
    backend = Backend()
    backend.jev = jev_response(task="find_photo")
    events = run_with_persona(backend, "car_salesman", line("Got a picture of it?"))

    done = next(event for event in events if event["type"] == "task_done")
    assert done["image_url"] == IMAGE_URL
    assert any("make and model" in r["system"] for r in backend.claude_requests)


def test_websocket_sets_the_persona_and_rejects_unknown_ones():
    backend = Backend()
    with TestClient(create_app(backend.deps)) as client:
        with client.websocket_connect("/ws") as ws:
            ws.send_json({"type": "set_persona", "persona": "pirate"})
            assert ws.receive_json()["type"] == "error"

            ws.send_json({"type": "set_persona", "persona": "first_date"})
            assert ws.receive_json() == {"type": "persona", "persona": "first_date"}

            ws.send_json({"type": "transcript", "text": "Tell me about yourself?"})
            assert ws.receive_json()["type"] == "transcript"
            assert ws.receive_json()["type"] == "whisper"

    assert "first date" in backend.claude_requests[0]["system"]


def test_persona_outlives_a_reconnect_on_the_same_session():
    backend = Backend()
    with TestClient(create_app(backend.deps)) as client:
        with client.websocket_connect("/ws?session_id=s1") as ws:
            ws.send_json({"type": "set_persona", "persona": "interview"})
            ws.receive_json()
        client.post("/transcript", params={"session_id": "s1"}, json={"text": "Why this job?"})

    assert "mock interview" in backend.claude_requests[0]["system"]


def test_post_transcript_takes_a_persona():
    backend = Backend()
    with TestClient(create_app(backend.deps)) as client:
        assert (
            client.post("/transcript", params={"persona": "pirate"}, json={"text": "Hi?"}).status_code
            == 422
        )
        response = client.post("/transcript", params={"persona": "car_salesman"}, json={"text": "Hi?"})

    assert response.status_code == 200
    assert "used car" in backend.claude_requests[0]["system"]


def test_shared_token_is_enforced_when_set():
    backend = Backend(app_shared_token="secret")
    body = {"text": "Which show?"}
    with TestClient(create_app(backend.deps)) as client:
        assert client.post("/transcript", json=body).status_code == 401
        assert (
            client.post("/transcript", json=body, headers={"X-App-Token": "secret"}).status_code
            == 200
        )
        assert client.get("/health").json()["jev_key"] is True


def image_bytes(width: int, height: int) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (width, height), (180, 40, 90)).save(buffer, "JPEG")
    return buffer.getvalue()


def photo_search(*images: tuple[str, int, int]) -> dict:
    """Run a photo task where search returns these (url, width, height) results in rank order."""
    backend = Backend()
    backend.search_results = [{"title": url, "properties": {"url": url}} for url, _, _ in images]
    backend.images = {url: image_bytes(width, height) for url, width, height in images}
    return done_event(backend)


def test_search_prefers_a_vertical_phone_photo_over_a_higher_ranked_landscape():
    done = photo_search(
        ("https://img.example/wide.jpg", 1600, 900),
        ("https://img.example/tall.jpg", 1080, 1920),
    )

    assert done["image_url"] == "https://img.example/tall.jpg"
    assert done["portrait"] is True


def test_search_uses_the_best_landscape_when_nothing_is_vertical():
    done = photo_search(
        ("https://img.example/first.jpg", 1600, 900),
        ("https://img.example/second.jpg", 1200, 800),
    )

    assert done["image_url"] == "https://img.example/first.jpg"
    assert done["portrait"] is False


def test_search_skips_vertical_thumbnails_too_small_to_pass_for_a_phone_photo():
    done = photo_search(
        ("https://img.example/tiny.jpg", 200, 300),
        ("https://img.example/wide.jpg", 1600, 900),
    )

    assert done["image_url"] == "https://img.example/wide.jpg"


def test_unsized_images_still_count_but_rank_after_vertical_ones():
    backend = Backend()
    backend.search_results = [
        {"properties": {"url": "https://img.example/mystery.jpg"}},
        {"properties": {"url": "https://img.example/tall.jpg"}},
    ]
    backend.images = {"https://img.example/tall.jpg": image_bytes(900, 1600)}

    assert done_event(backend)["image_url"] == "https://img.example/tall.jpg"


def test_photo_query_asks_for_the_place_and_a_crowd_shot():
    backend = Backend()
    done_event(backend)

    system = next(r["system"] for r in backend.claude_requests if "image search query" in r["system"])
    assert "add Toronto only for a local place or event" in system
    assert '"crowd"' in system



def test_word_cap_doesnt_cut_a_number_at_its_decimal_point():
    line = "Say head gaskets are a myth, friend. Say this Outback has the 2.5 boxer that never blew once."

    assert cap_words(line) == "Say head gaskets are a myth, friend."


@pytest.mark.parametrize(
    "raw, cleaned",
    [
        ("Say: Your brother's not wrong", "Say Your brother's not wrong"),
        ('Say: "Honestly, I once missed a deadline', "Say Honestly, I once missed a deadline"),
        ("Say you caught her at Massey Hall", "Say you caught her at Massey Hall"),
    ],
)
def test_clean_line_drops_the_colon_after_say(raw, cleaned):
    assert clean_line(raw) == cleaned


def ranked_search(results: list[dict], rank: dict[str, float] | None, looks: dict[str, str] | None = None) -> dict:
    """A photo task where search returns these vertical, phone-sized results in this order."""
    backend = Backend()
    backend.search_results = results
    backend.images = {r["properties"]["url"]: image_bytes(1080, 1920) for r in results}
    backend.photo_rank = rank
    backend.looks = looks or {}
    return done_event(backend)


PRESS = {
    "title": "Drake speaks at a press conference",
    "source": "gettyimages.com",
    "properties": {"url": "https://img.example/press.jpg"},
    "thumbnail": {"src": "https://thumb.example/press.jpg"},
}
CONCERT = {
    "title": "Drake performs at Scotiabank Arena, It's All A Blur tour",
    "source": "instagram.com",
    "properties": {"url": "https://img.example/concert.jpg"},
    "thumbnail": {"src": "https://thumb.example/concert.jpg"},
}


def test_jev_ranks_a_real_concert_photo_above_a_press_photo():
    done = ranked_search([PRESS, CONCERT], rank={"r0": 0.1, "r1": 0.9})

    assert done["image_url"] == CONCERT["properties"]["url"]


def timed_search(backend: Backend, use_claude: bool) -> tuple[photo_module.Photo | None, float]:
    async def go():
        claude = backend.deps.claude if use_claude else None
        return await photo_module._search(backend.deps.http, backend.deps.settings, "Drake concert crowd", claude)

    start = time.perf_counter()
    photo = asyncio.run(go())
    return photo, time.perf_counter() - start


def test_jev_ranks_while_the_photo_sizes_are_checked():
    backend = Backend()
    backend.search_results = [PRESS, CONCERT]
    backend.images = {r["properties"]["url"]: image_bytes(1080, 1920) for r in [PRESS, CONCERT]}
    backend.photo_rank = {"r0": 0.1, "r1": 0.9}
    # Jev and the image host each take 0.3 s: one after the other would be 0.6 s.
    backend.delays = {"api.typesafe.ai": 0.3, "img.example": 0.3}

    photo, seconds = timed_search(backend, use_claude=False)

    assert photo.image_url == CONCERT["properties"]["url"]
    assert seconds < 0.5


def test_the_best_photo_goes_out_without_waiting_on_slower_looks():
    backend = Backend()
    backend.search_results = [CONCERT, PRESS]
    backend.images = {r["properties"]["url"]: image_bytes(1080, 1920) for r in [PRESS, CONCERT]}
    backend.photo_rank = {"r0": 0.9, "r1": 0.1}
    backend.delays = {PRESS["thumbnail"]["src"]: 2.0}

    photo, seconds = timed_search(backend, use_claude=True)

    assert photo.image_url == CONCERT["properties"]["url"]
    assert seconds < 1.0


def test_jev_sees_titles_and_sources_not_just_urls():
    backend = Backend()
    backend.search_results = [PRESS, CONCERT]
    backend.photo_rank = {"r0": 0.5, "r1": 0.5}
    done_event(backend)

    ask = next(r for r in backend.jev_requests if "best_photo" in r["questions"])
    criteria = ask["questions"]["best_photo"]["criteria"]
    assert criteria["r0"] == "Drake speaks at a press conference (from gettyimages.com)"
    assert "Scotiabank Arena" in criteria["r1"]


def test_haiku_looking_at_the_photo_can_reject_jevs_pick():
    done = ranked_search(
        [PRESS, CONCERT],
        rank={"r0": 0.1, "r1": 0.9},
        looks={"https://thumb.example/concert.jpg": "no"},
    )

    assert done["image_url"] == PRESS["properties"]["url"]


def test_nothing_is_sent_when_haiku_rejects_every_photo(tmp_path, monkeypatch):
    monkeypatch.setattr(photo_module, "ASSETS_DIR", tmp_path)  # no cached photo either
    done = ranked_search(
        [PRESS, CONCERT],
        rank={"r0": 0.5, "r1": 0.5},
        looks={"https://thumb.example/concert.jpg": "No.", "https://thumb.example/press.jpg": "no"},
    )

    assert done["ok"] is False


def test_when_jev_cant_rank_the_search_order_stands():
    done = ranked_search([PRESS, CONCERT], rank=None)

    assert done["image_url"] == PRESS["properties"]["url"]


def test_an_unclear_look_still_allows_the_photo():
    done = ranked_search([CONCERT], rank=None, looks={"https://thumb.example/concert.jpg": "It's hard to say"})

    assert done["image_url"] == CONCERT["properties"]["url"]


@pytest.mark.parametrize(
    "raw, cleaned",
    [
        ("Say you caught her at Massey Hall and name a song you remember", "Say you caught her at Massey Hall"),
        ("Say you saw the show, then pick one from the set", "Say you saw the show"),
        ("Say the Massey Hall show wrecked you", "Say the Massey Hall show wrecked you"),
        ("Say the third song was From the Start and name-drop nobody", "Say the third song was From the Start and name-drop nobody"),
    ],
)
def test_trailing_instructions_are_dropped_from_the_screen_line(raw, cleaned):
    assert drop_trailing_instruction(raw) == cleaned
