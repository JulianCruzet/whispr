import asyncio
import logging
from dataclasses import dataclass

import httpx

from app.config import ASSETS_DIR, FALLBACK_PHOTO, Settings

log = logging.getLogger(__name__)

BRAVE_IMAGES_URL = "https://api.search.brave.com/res/v1/images/search"
MAX_CANDIDATES = 5


@dataclass
class Photo:
    image_url: str
    title: str | None = None
    used_fallback: bool = False


async def _loads_as_image(http: httpx.AsyncClient, url: str) -> bool:
    if not url.startswith("https://"):
        return False
    try:
        async with http.stream("GET", url, follow_redirects=True) as response:
            content_type = response.headers.get("content-type", "")
            return response.status_code == 200 and content_type.startswith("image/")
    except httpx.HTTPError:
        return False


async def _search(http: httpx.AsyncClient, settings: Settings, query: str) -> Photo | None:
    response = await http.get(
        BRAVE_IMAGES_URL,
        headers={"X-Subscription-Token": settings.brave_search_api_key},
        params={"q": query, "count": MAX_CANDIDATES},
    )
    response.raise_for_status()
    # Results come back ranked, so the best photo is the first one that actually loads.
    for result in response.json().get("results", []):
        url = result.get("properties", {}).get("url", "")
        if await _loads_as_image(http, url):
            return Photo(image_url=url, title=result.get("title"))
    return None


def fallback_photo(settings: Settings) -> Photo | None:
    if settings.fallback_photo_url:
        image_url = settings.fallback_photo_url
    elif (ASSETS_DIR / FALLBACK_PHOTO).is_file():
        image_url = f"{settings.base_url}/assets/{FALLBACK_PHOTO}"
    else:
        log.error("No FALLBACK_PHOTO_URL and no cached photo at %s", ASSETS_DIR / FALLBACK_PHOTO)
        return None
    return Photo(image_url=image_url, title="Laufey at Scotiabank Arena", used_fallback=True)


async def find_photo(
    http: httpx.AsyncClient, settings: Settings, query: str, use_cached: bool = True
) -> Photo | None:
    photo = None
    if settings.brave_search_api_key:
        try:
            async with asyncio.timeout(settings.photo_deadline_s):
                photo = await _search(http, settings, query)
        except (TimeoutError, httpx.HTTPError, ValueError) as exc:
            log.warning("Photo search failed: %r", exc)
    else:
        log.warning("No BRAVE_SEARCH_API_KEY, so no photo search")
    return photo or (fallback_photo(settings) if use_cached else None)
