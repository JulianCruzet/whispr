from dataclasses import dataclass

import httpx

from app.config import Settings

JEV_URL = "https://api.typesafe.ai/v1/systemone"
JEV_TIMEOUT_S = 3.0

RISK_LEVELS = [
    "Relaxed; the other person fully believes the wearer",
    "Mild curiosity; they are asking for a detail or two",
    "Suspicious; they are testing the wearer's story",
    "Nearly caught; they openly doubt the wearer",
]

QUESTIONS = {
    "should_whisper": {
        "type": "noul",
        "instructions": (
            "The latest line puts the wearer on the spot, so they need something to say right now."
        ),
    },
    "who_spoke": {
        "type": "choice",
        "instructions": "Who said the latest line?",
        "criteria": {
            "me": "The wearer, the person telling the cover story",
            "them": "The other person, the one asking about or reacting to the story",
        },
    },
    "launch_task": {
        "type": "choice",
        "instructions": "What background task would help the wearer after the latest line?",
        "criteria": {
            "none": "Nothing needs fetching; talking is enough",
            "find_photo": "A photo would prove the wearer was there or saw something",
            "look_up_fact": "The wearer needs a specific fact they are unlikely to know",
        },
    },
    "cover_blown_risk": {
        "type": "score",
        "instructions": "How close is the wearer to getting caught bluffing?",
        "criteria": RISK_LEVELS,
    },
}


@dataclass
class Decision:
    should_whisper: float
    who_spoke: str
    launch_task: str
    launch_probability: float
    cover_blown_risk: float  # Normalized to 0-1.


async def decide(http: httpx.AsyncClient, settings: Settings, state: str) -> Decision:
    response = await http.post(
        JEV_URL,
        headers={"Authorization": f"Bearer {settings.jev_api_key}"},
        json={"state": state, "model": settings.jev_model, "questions": QUESTIONS},
        timeout=JEV_TIMEOUT_S,
    )
    response.raise_for_status()
    answers = response.json()["answers"]

    task = answers["launch_task"]
    return Decision(
        should_whisper=answers["should_whisper"]["noul"],
        who_spoke=answers["who_spoke"]["choice"],
        launch_task=task["choice"],
        launch_probability=task["probabilities"][task["choice"]],
        cover_blown_risk=answers["cover_blown_risk"]["score"] / (len(RISK_LEVELS) - 1),
    )
