from typing import Literal

from pydantic import BaseModel, Field


class TranscriptIn(BaseModel):
    type: Literal["transcript"] = "transcript"
    text: str = Field(min_length=1, max_length=2000)
    # "me" / "them" is trusted as is. Anything else, like a Scribe label, is only a hint to Jev.
    speaker: str | None = None
    # Partial Scribe results are ignored; only committed lines reach Jev.
    is_final: bool = True


class PersonaIn(BaseModel):
    type: Literal["set_persona"]
    persona: str
