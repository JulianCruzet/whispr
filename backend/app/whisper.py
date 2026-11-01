import re
from typing import NamedTuple

import anthropic

from app.config import Settings
from app.personas import DEFAULT_PERSONA, Persona
from app.prompts import PHOTO_COMING_NOTE, photo_query_system, whisper_system

MAX_WHISPER_WORDS = 15
# The ear gets a short cue: a long line spoken mid-conversation is hard to follow.
MAX_SPOKEN_WORDS = 5


class Whisper(NamedTuple):
    text: str
    """The line on the screen, starting with "Say"."""
    spoken: str
    """The few words spoken in the ear."""


async def _complete(
    client: anthropic.AsyncAnthropic, settings: Settings, system: str, transcript: str
) -> str | None:
    response = await client.messages.create(
        model=settings.whisper_model,
        max_tokens=90,
        thinking={"type": "disabled"},
        output_config={"effort": "low"},
        system=system,
        messages=[{"role": "user", "content": transcript}],
    )
    if response.stop_reason == "refusal":
        return None
    return "".join(block.text for block in response.content if block.type == "text").strip()


# "1. ", "Ear:" and the like, in case Haiku labels its two lines anyway.
_LABEL = re.compile(r"^(?:\d[.)]\s+|(?:screen|ear|card|line \d)\s*:\s*)+", re.IGNORECASE)


def clean_line(text: str) -> str:
    lines = text.splitlines()
    if not lines:
        return ""
    line = _LABEL.sub("", lines[0].strip())
    # Haiku sometimes writes `Say: "..."`, which the voice would read out as "Say colon".
    return re.sub(r'^Say:\s*["“]?', "Say ", line).strip('"“”')


def clean_cue(text: str) -> str:
    """The ear line: no label, quotes or leading "Say (that)"."""
    cue = re.sub(r"^Say(?: that)?\b[:,]?\s*", "", clean_line(text), flags=re.IGNORECASE).strip('"“” ')
    return cue[:1].upper() + cue[1:]


def cap_words(line: str, limit: int = MAX_WHISPER_WORDS) -> str:
    words = line.split()
    capped = " ".join(words[:limit])
    if len(words) <= limit:
        return capped
    # Over the cap: end on the last clause that fits, so it doesn't stop mid-sentence.
    # The mark must end a word, so a number like 2.5 isn't taken for the end of a sentence.
    ends = [match.end() for match in re.finditer(r"[.!?,](?=\s|$)", capped)]
    return capped[: ends[-1]].rstrip(",") if ends else capped


def drop_trailing_instruction(line: str) -> str:
    # Haiku sometimes ends with "and name a song", which leaves the wearer to do the thinking.
    return re.sub(r",?\s+(?:and|then)\s+(?:name|pick|mention)\s+(?:a|an|one|the|some)\b.*$", "", line, flags=re.IGNORECASE)


async def write_whisper(
    client: anthropic.AsyncAnthropic,
    settings: Settings,
    transcript: str,
    photo_coming: bool = False,
    persona: Persona = DEFAULT_PERSONA,
) -> Whisper | None:
    content = f"{transcript}\n\n{PHOTO_COMING_NOTE}" if photo_coming else transcript
    text = await _complete(client, settings, whisper_system(persona), content)
    lines = [line for line in (text or "").splitlines() if line.strip()]
    if not lines:
        return None
    shown = cap_words(drop_trailing_instruction(clean_line(lines[0])))
    if not shown:
        return None
    # If Haiku wrote only one line, the ear gets the whole thing, as before.
    spoken = cap_words(clean_cue(lines[1]), MAX_SPOKEN_WORDS) if len(lines) > 1 else ""
    return Whisper(shown, spoken or shown)


async def write_photo_query(
    client: anthropic.AsyncAnthropic,
    settings: Settings,
    transcript: str,
    persona: Persona = DEFAULT_PERSONA,
) -> str | None:
    text = await _complete(client, settings, photo_query_system(persona), transcript)
    return clean_line(text) or None if text else None
