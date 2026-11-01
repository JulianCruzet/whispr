from dataclasses import dataclass

GAME = "Whispr is a lighthearted improv game made for LarpHacks. The wearer has an earpiece and"


@dataclass(frozen=True)
class Persona:
    id: str
    scenario: str
    # What a photo search should name. None means this persona never looks for photos.
    photo_hint: str | None = None
    # The cached photo suits the fan's stories, so only the fan can fall back to it.
    uses_cached_photo: bool = False


PERSONAS = {
    persona.id: persona
    for persona in (
        Persona(
            id="fan",
            scenario=(
                f"{GAME} stays in character during casual, low-stakes small talk: whatever the "
                "other person brings up, the wearer is into it too and has been there or seen it. "
                "The wearer lives in Toronto."
            ),
            photo_hint="who or what and where (add Toronto only for a local place or event)",
            uses_cached_photo=True,
        ),
        Persona(
            id="interview",
            scenario=(
                f"{GAME} is playing a job candidate in a mock interview with a friend. Whatever "
                "role or skill comes up, in character they have done it before and love it. They "
                "stay friendly, confident and a little too polished."
            ),
        ),
        Persona(
            id="first_date",
            scenario=(
                f"{GAME} is playing someone on a pretend first date with a friend. In character "
                "they are charming and curious, love whatever the date brings up, and have a fun "
                "story about it."
            ),
            photo_hint="the place or activity being talked about",
        ),
        Persona(
            id="car_salesman",
            scenario=(
                f"{GAME} is playing an over-the-top used car salesperson in a comedy sketch, with "
                "a friend playing the customer. In character every car on the lot is a gem and "
                "every objection is a selling point."
            ),
            photo_hint="the make and model of the car being talked about",
        ),
    )
}

DEFAULT_PERSONA = PERSONAS["fan"]
