import asyncio
import io
import json

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
from app.prompts import PHOTO_COMING_NOTE
from app.session import PHOTO_READY_WHISPER, Deps, Session
from app.whisper import write_whisper

IMAGE_URL = "https://img.example/laufey.jpg"


def jev_response(should_whisper=0.95, who="them", task="none", task_p=0.9, risk=1.5):
    return {
        "answers": {
            "should_whisper": {"type": "noul", "noul": should_whisper},
            "who_spoke": {"type": "choice", "choice": who},
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
        self.claude_requests = []
        self.jev_requests = []

        self.deps = Deps(
            settings=Settings(
                _env_file=None,
                anthropic_api_key="test",
                jev_api_key="test",
                brave_search_api_key="test",
                public_base_url="https://roxy.example",
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

    def _http(self, request: httpx.Request) -> httpx.Response:
        if request.url.host == "api.typesafe.ai":
            self.jev_requests.append(json.loads(request.content))
            return httpx.Response(200, json=self.jev)
        if request.url.host == "api.search.brave.com":
            if self.fail_search:
                return httpx.Response(500)
            return httpx.Response(200, json={"results": self.search_results})
        body = self.images.get(str(request.url), b"jpg")
        return httpx.Response(200, headers={"content-type": "image/jpeg"}, content=body)

    def _claude(self, request: httpx2.Request) -> httpx2.Response:
        self.claude_requests.append(json.loads(request.content))
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
    # The only Haiku call wrote the search query; nothing was written back at the wearer.
    assert len(backend.claude_requests) == 1
    assert "image search query" in backend.claude_requests[0]["system"]


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
    assert done["image_url"] == "https://roxy.example/assets/fallback.jpg"


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

    assert "Scotiabank Arena" in backend.claude_requests[0]["system"]
    assert "Scotiabank Arena" in backend.jev_requests[0]["state"]


@pytest.mark.parametrize(
    "persona_id, phrase",
    [("interview", "mock interview"), ("first_date", "first date"), ("car_salesman", "used car")],
)
def test_persona_shapes_the_whisper_and_jev(persona_id, phrase):
    backend = Backend()
    run_with_persona(backend, persona_id, line("Tell me more?"))

    assert phrase in backend.claude_requests[0]["system"]
    assert "Scotiabank Arena" not in backend.claude_requests[0]["system"]
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


def test_photo_query_asks_for_the_venue_and_a_crowd_shot():
    backend = Backend()
    done_event(backend)

    system = next(r["system"] for r in backend.claude_requests if "image search query" in r["system"])
    assert "Scotiabank Arena" in system
    assert '"crowd"' in system

