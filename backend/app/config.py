from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

BACKEND_DIR = Path(__file__).resolve().parents[1]
ASSETS_DIR = BACKEND_DIR / "assets"
FALLBACK_PHOTO = "fallback.jpg"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=(BACKEND_DIR.parent / ".env", BACKEND_DIR / ".env"),
        extra="ignore",
    )

    anthropic_api_key: str = ""
    jev_api_key: str = ""
    brave_search_api_key: str = ""
    app_shared_token: str = ""
    fallback_photo_url: str = ""
    public_base_url: str = ""
    render_external_url: str = ""

    whisper_model: str = "claude-haiku-5-5"
    jev_model: str = "jev-latest"

    # Noul guidance from the Jev docs: start at 0.7 for "yes".
    should_whisper_threshold: float = 0.7
    launch_task_threshold: float = 0.6
    whisper_cooldown_s: float = 5.0
    photo_cooldown_s: float = 30.0
    # Search, Jev's ranking and Haiku's look at the top photos all fit in this.
    photo_deadline_s: float = 8.0

    @property
    def base_url(self) -> str:
        url = self.public_base_url or self.render_external_url or "http://localhost:8000"
        return url.rstrip("/")
