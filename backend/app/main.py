import asyncio
import hmac
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import anthropic
import httpx
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
from pydantic import TypeAdapter, ValidationError
from starlette.requests import HTTPConnection

from app.config import ASSETS_DIR, FALLBACK_PHOTO, Settings
from app.events import PersonaIn, TranscriptIn
from app.personas import PERSONAS
from app.session import Deps, Session

logging.basicConfig(level=logging.INFO)

WS_MESSAGE = TypeAdapter(TranscriptIn | PersonaIn)


def build_deps() -> Deps:
    settings = Settings()
    return Deps(
        settings=settings,
        http=httpx.AsyncClient(timeout=4.0),
        # Short timeout, one retry: a whisper that arrives late is useless anyway.
        claude=anthropic.AsyncAnthropic(
            api_key=settings.anthropic_api_key or None, timeout=4.0, max_retries=1
        ),
    )


def create_app(deps: Deps | None = None) -> FastAPI:
    deps = deps or build_deps()
    sessions: dict[str, Session] = {}

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        yield
        await deps.http.aclose()
        await deps.claude.close()

    app = FastAPI(title="Roxy backend", lifespan=lifespan)
    app.mount("/assets", StaticFiles(directory=ASSETS_DIR, check_dir=False), name="assets")

    def get_session(session_id: str) -> Session:
        return sessions.setdefault(session_id, Session(deps))

    def authorized(conn: HTTPConnection) -> bool:
        expected = deps.settings.app_shared_token
        if not expected:
            return True
        given = conn.headers.get("x-app-token") or conn.query_params.get("token") or ""
        return hmac.compare_digest(given.encode(), expected.encode())

    @app.get("/health")
    async def health() -> dict:
        settings = deps.settings
        return {
            "ok": True,
            "anthropic_key": bool(settings.anthropic_api_key),
            "jev_key": bool(settings.jev_api_key),
            "brave_key": bool(settings.brave_search_api_key),
            "fallback_photo": bool(settings.fallback_photo_url)
            or (ASSETS_DIR / FALLBACK_PHOTO).is_file(),
        }

    @app.post("/transcript")
    async def post_transcript(
        msg: TranscriptIn,
        request: Request,
        session_id: str = "default",
        wait_tasks: bool = False,
        persona: str | None = None,
    ) -> dict:
        """One-shot version of /ws for testing. Late task events need wait_tasks=true."""
        if not authorized(request):
            raise HTTPException(status_code=401, detail="Bad app token")

        session = get_session(session_id)
        if persona is not None and not session.set_persona(persona):
            raise HTTPException(status_code=422, detail=f"Unknown persona. Use one of {list(PERSONAS)}")
        events: list[dict] = []

        async def collect(event: dict) -> None:
            events.append(event)

        session.listeners.add(collect)
        try:
            await session.handle_transcript(msg)
            if wait_tasks and session.tasks:
                await asyncio.gather(*session.tasks)
        finally:
            session.listeners.discard(collect)
        return {"events": events}

    @app.websocket("/ws")
    async def ws_endpoint(ws: WebSocket, session_id: str = "default") -> None:
        if not authorized(ws):
            await ws.close(code=1008)
            return
        await ws.accept()

        session = get_session(session_id)
        send_lock = asyncio.Lock()

        async def send(event: dict) -> None:
            async with send_lock:
                await ws.send_json(event)

        session.listeners.add(send)
        try:
            while True:
                raw = await ws.receive_text()
                try:
                    msg = WS_MESSAGE.validate_json(raw)
                except ValidationError as exc:
                    await send({"type": "error", "detail": exc.errors(include_url=False, include_input=False)})
                    continue
                if isinstance(msg, PersonaIn):
                    if session.set_persona(msg.persona):
                        await send({"type": "persona", "persona": msg.persona})
                    else:
                        await send({"type": "error", "detail": f"Unknown persona. Use one of {list(PERSONAS)}"})
                    continue
                # Not awaited, so a slow Jev or Haiku call never blocks the next line.
                session.spawn(session.handle_transcript(msg))
        except WebSocketDisconnect:
            pass
        finally:
            session.listeners.discard(send)

    return app


app = create_app()
