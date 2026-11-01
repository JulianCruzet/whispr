import asyncio
import json

import anthropic
import httpx
import httpx2
import pytest
from fastapi.testclient import TestClient

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
        return httpx.Response(200, headers={"content-type": "image/jpeg"}, content=b"jpg")

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
    backend.jev = jev_response(who="me", task="find_photo")
    events = run_line(backend, line("I saw her in Toronto."))

    assert types(events) == ["transcript"]
    assert backend.claude_requests == []


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
