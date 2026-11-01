import anthropic

from app.config import Settings
from app.prompts import PHOTO_COMING_NOTE, PHOTO_QUERY_SYSTEM, WHISPER_SYSTEM

MAX_WHISPER_WORDS = 15


async def _complete(
    client: anthropic.AsyncAnthropic, settings: Settings, system: str, transcript: str
) -> str | None:
    response = await client.messages.create(
        model=settings.whisper_model,
        max_tokens=60,
        thinking={"type": "disabled"},
        output_config={"effort": "low"},
        system=system,
        messages=[{"role": "user", "content": transcript}],
    )
    if response.stop_reason == "refusal":
        return None
    return "".join(block.text for block in response.content if block.type == "text").strip()


def clean_line(text: str) -> str:
    lines = text.splitlines()
    return lines[0].strip().strip('"“”') if lines else ""


def cap_words(line: str) -> str:
    words = line.split()
    capped = " ".join(words[:MAX_WHISPER_WORDS])
    if len(words) <= MAX_WHISPER_WORDS:
        return capped
    # Over the cap: end on the last clause that fits, so it doesn't stop mid-sentence.
    end = max(capped.rfind(mark) for mark in ".!?,")
    return capped[: end + 1].rstrip(",") if end > 0 else capped


async def write_whisper(
    client: anthropic.AsyncAnthropic,
    settings: Settings,
    transcript: str,
    photo_coming: bool = False,
) -> str | None:
    content = f"{transcript}\n\n{PHOTO_COMING_NOTE}" if photo_coming else transcript
    text = await _complete(client, settings, WHISPER_SYSTEM, content)
    if not text:
        return None
    return cap_words(clean_line(text)) or None


async def write_photo_query(
    client: anthropic.AsyncAnthropic, settings: Settings, transcript: str
) -> str | None:
    text = await _complete(client, settings, PHOTO_QUERY_SYSTEM, transcript)
    return clean_line(text) or None if text else None
