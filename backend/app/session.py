import asyncio
import logging
import time
import uuid
from collections import deque
from collections.abc import Awaitable, Callable, Coroutine
from dataclasses import dataclass

import anthropic
import httpx

from app.config import Settings
from app.events import TranscriptIn
from app.jev import Decision, decide
from app.personas import DEFAULT_PERSONA, PERSONAS
from app.photo import find_photo
from app.whisper import write_photo_query, write_whisper

log = logging.getLogger(__name__)

HISTORY_LINES = 12
PHOTO_READY_WHISPER = "The photo's in your camera roll. Show them now."
PHOTO_READY_SPOKEN = "Photo found. It's in your camera roll."

Listener = Callable[[dict], Awaitable[None]]


@dataclass
class Deps:
    settings: Settings
    http: httpx.AsyncClient
    claude: anthropic.AsyncAnthropic


class Session:
    def __init__(self, deps: Deps) -> None:
        self.deps = deps
        self.persona = DEFAULT_PERSONA
        self.history: deque[dict] = deque(maxlen=HISTORY_LINES)
        self.listeners: set[Listener] = set()
        self.tasks: set[asyncio.Task] = set()
        self.last_whisper_at = float("-inf")
        self.last_photo_at = float("-inf")
        self.photo_in_flight = False

    async def emit(self, event: dict) -> None:
        for listener in list(self.listeners):
            try:
                await listener(event)
            except Exception:
                log.info("Dropping a disconnected listener")
                self.listeners.discard(listener)

    def spawn(self, coro: Coroutine) -> asyncio.Task:
        task = asyncio.create_task(coro)
        self.tasks.add(task)
        task.add_done_callback(self._task_finished)
        return task

    def _task_finished(self, task: asyncio.Task) -> None:
        self.tasks.discard(task)
        if not task.cancelled() and task.exception():
            log.error("Background task crashed", exc_info=task.exception())

    def set_persona(self, persona_id: str) -> bool:
        persona = PERSONAS.get(persona_id)
        if persona is None:
            return False
        # A new persona is a new scene, so lines from the old one shouldn't colour it.
        if persona is not self.persona:
            self.persona = persona
            self.history.clear()
        return True

    def _transcript_text(self) -> str:
        return "\n".join(f"[{line['speaker']}] {line['text']}" for line in self.history)

    def _jev_state(self) -> str:
        return f"{self.persona.scenario}\n\nConversation so far, oldest first:\n{self._transcript_text()}"

    async def handle_transcript(self, msg: TranscriptIn) -> None:
        text = msg.text.strip()
        if not msg.is_final or not text:
            return

        line = {"speaker": msg.speaker or "unknown", "text": text}
        self.history.append(line)

        try:
            decision = await decide(self.deps.http, self.deps.settings, self._jev_state())
        except (httpx.HTTPError, KeyError, TypeError, ValueError) as exc:
            log.warning("Jev call failed, skipping this line: %r", exc)
            await self.emit(
                {"type": "transcript", "text": text, "who_spoke": msg.speaker, "cover_blown_risk": None}
            )
            return

        who_spoke = msg.speaker if msg.speaker in ("me", "them") else decision.who_spoke
        line["speaker"] = who_spoke
        await self.emit(
            {
                "type": "transcript",
                "text": text,
                "who_spoke": who_spoke,
                "cover_blown_risk": decision.cover_blown_risk,
            }
        )

        # The wearer's own claim ("I was at Drake last night") can call for proof,
        # but only their turn gets coached: never whisper back at the wearer's own words.
        if who_spoke in ("me", "them"):
            self._maybe_launch_task(decision)
        if who_spoke == "them":
            await self._maybe_whisper(decision)

    async def _maybe_whisper(self, decision: Decision) -> None:
        settings = self.deps.settings
        now = time.monotonic()
        if decision.should_whisper < settings.should_whisper_threshold:
            return
        if now - self.last_whisper_at < settings.whisper_cooldown_s:
            return

        # Claimed before the await so a line arriving mid-call can't double-whisper.
        previous_whisper_at = self.last_whisper_at
        self.last_whisper_at = now
        try:
            whisper = await write_whisper(
                self.deps.claude,
                settings,
                self._transcript_text(),
                photo_coming=self.photo_in_flight,
                persona=self.persona,
            )
        except anthropic.APIError as exc:
            log.warning("Whisper call failed: %r", exc)
            whisper = None

        if not whisper:
            self.last_whisper_at = previous_whisper_at
            return
        await self._send_whisper(
            whisper.text, whisper.spoken, reason="reply", cover_blown_risk=decision.cover_blown_risk
        )

    async def _send_whisper(
        self, text: str, spoken: str, reason: str, cover_blown_risk: float | None
    ) -> None:
        await self.emit(
            {
                "type": "whisper",
                "id": uuid.uuid4().hex,
                # `text` goes on the screen; `spoken` is what the gateway says in the ear.
                "text": text,
                "spoken": spoken,
                "reason": reason,
                "cover_blown_risk": cover_blown_risk,
            }
        )

    def _maybe_launch_task(self, decision: Decision) -> None:
        settings = self.deps.settings
        # look_up_fact is a stretch goal, so Jev can pick it but nothing runs yet.
        if decision.launch_task != "find_photo" or self.persona.photo_hint is None:
            return
        if decision.launch_probability < settings.launch_task_threshold:
            return
        now = time.monotonic()
        if self.photo_in_flight or now - self.last_photo_at < settings.photo_cooldown_s:
            return

        self.photo_in_flight = True
        self.last_photo_at = now
        self.spawn(self._run_photo_task())

    async def _run_photo_task(self) -> None:
        settings = self.deps.settings
        persona = self.persona
        task_id = uuid.uuid4().hex
        done = {"type": "task_done", "task_id": task_id, "task": "find_photo", "ok": False}
        try:
            await self.emit({"type": "task_started", "task_id": task_id, "task": "find_photo"})
            query = self.history[-1]["text"]
            try:
                query = (
                    await write_photo_query(
                        self.deps.claude, settings, self._transcript_text(), persona=persona
                    )
                    or query
                )
            except anthropic.APIError as exc:
                log.warning("Photo query call failed, using the default: %r", exc)

            photo = await find_photo(
                self.deps.http,
                settings,
                query,
                use_cached=persona.uses_cached_photo,
                claude=self.deps.claude,
            )
            if photo:
                done |= {
                    "ok": True,
                    "image_url": photo.image_url,
                    "title": photo.title,
                    "query": query,
                    "used_fallback": photo.used_fallback,
                    # False means a landscape (or unsized) photo; the app crops it to portrait.
                    "portrait": photo.is_portrait,
                }
        except Exception:
            log.exception("Photo task failed")
        finally:
            self.photo_in_flight = False

        await self.emit(done)
        if done["ok"]:
            # Skips the cooldown: this is the payoff line and it can't wait for a later turn.
            self.last_whisper_at = time.monotonic()
            await self._send_whisper(
                PHOTO_READY_WHISPER, PHOTO_READY_SPOKEN, reason="task_done", cover_blown_risk=None
            )
