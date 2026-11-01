import re

import anthropic

from app.config import Settings
from app.personas import DEFAULT_PERSONA, Persona
from app.prompts import PHOTO_COMING_NOTE, photo_query_system, whisper_system

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
    if not lines:
        return ""
    # Haiku sometimes writes `Say: "..."`, which the voice would read out as "Say colon".
    return re.sub(r'^Say:\s*["“]?', "Say ", lines[0].strip()).strip('"“”')


def cap_words(line: str) -> str:
    words = line.split()
    capped = " ".join(words[:MAX_WHISPER_WORDS])
    if len(words) <= MAX_WHISPER_WORDS:
        return capped
    # Over the cap: end on the last clause that fits, so it doesn't stop mid-sentence.
    # The mark must end a word, so a number like 2.5 isn't taken for the end of a sentence.
    ends = [match.end() for match in re.finditer(r"[.!?,](?=\s|$)", capped)]
    return capped[: ends[-1]].rstrip(",") if ends else capped


async def write_whisper(
    client: anthropic.AsyncAnthropic,
    settings: Settings,
    transcript: str,
    photo_coming: bool = False,
    persona: Persona = DEFAULT_PERSONA,
) -> str | None:
    content = f"{transcript}\n\n{PHOTO_COMING_NOTE}" if photo_coming else transcript
    text = await _complete(client, settings, whisper_system(persona), content)
    if not text:
        return None
    return cap_words(clean_line(text)) or None


async def write_photo_query(
    client: anthropic.AsyncAnthropic,
    settings: Settings,
    transcript: str,
    persona: Persona = DEFAULT_PERSONA,
) -> str | None:
    text = await _complete(client, settings, photo_query_system(persona), transcript)
    return clean_line(text) or None if text else None
