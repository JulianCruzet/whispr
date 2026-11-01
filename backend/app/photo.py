import asyncio
import logging
from dataclasses import dataclass

import httpx
from PIL import ImageFile

from app.config import ASSETS_DIR, FALLBACK_PHOTO, Settings

log = logging.getLogger(__name__)

BRAVE_IMAGES_URL = "https://api.search.brave.com/res/v1/images/search"
# Ask for plenty: most search photos are landscape, and we want one that looks shot on a phone.
SEARCH_COUNT = 20
# Top results checked at once. Each is read only until its size is known.
PROBE_COUNT = 10
PROBE_TIMEOUT_S = 2.5
# Enough to reach the size in any JPEG, PNG or WebP header, even behind a big EXIF block.
MAX_PROBE_BYTES = 512 * 1024
# At least this much taller than wide counts as a vertical phone photo.
PORTRAIT_RATIO = 1.15
# Smaller than this on the short side looks like a thumbnail, not a phone photo.
MIN_SHORT_SIDE = 400
# Many image hosts refuse non-browser clients (e.g. Wikimedia answers python-httpx with 403),
# so fetch images the way the phone's browser would.
IMAGE_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) AppleWebKit/605.1.15 "
        "(KHTML, like Gecko) Version/26.5 Mobile/15E148 Safari/604.1"
    ),
    "Accept": "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8",
}


@dataclass
class Photo:
    image_url: str
    title: str | None = None
    used_fallback: bool = False
    width: int | None = None
    height: int | None = None

    @property
    def is_portrait(self) -> bool:
        return bool(self.width and self.height and self.height >= self.width * PORTRAIT_RATIO)

    @property
    def too_small(self) -> bool:
        return bool(self.width and self.height and min(self.width, self.height) < MIN_SHORT_SIDE)


# Returned by _probe for an image that loads but whose size couldn't be read.
UNKNOWN_SIZE = (0, 0)


async def _probe(http: httpx.AsyncClient, url: str) -> tuple[int, int] | None:
    """(width, height) of the image at url, UNKNOWN_SIZE if it loads but can't be sized,
    or None if it doesn't load as an image at all."""
    if not url.startswith("https://"):
        return None
    try:
        async with asyncio.timeout(PROBE_TIMEOUT_S):
            async with http.stream("GET", url, headers=IMAGE_HEADERS, follow_redirects=True) as response:
                content_type = response.headers.get("content-type", "")
                if response.status_code != 200 or not content_type.startswith("image/"):
                    return None
                parser = ImageFile.Parser()
                read = 0
                async for chunk in response.aiter_bytes():
                    parser.feed(chunk)
                    read += len(chunk)
                    if parser.image is not None:
                        return parser.image.size
                    if read >= MAX_PROBE_BYTES:
                        break
                return UNKNOWN_SIZE
    except (TimeoutError, httpx.HTTPError):
        return None
    except Exception as exc:  # A malformed header can make Pillow raise; the image may still be fine.
        log.info("Couldn't read the size of %s: %r", url, exc)
        return UNKNOWN_SIZE


async def _search(http: httpx.AsyncClient, settings: Settings, query: str) -> Photo | None:
    response = await http.get(
        BRAVE_IMAGES_URL,
        headers={"X-Subscription-Token": settings.brave_search_api_key},
        params={"q": query, "count": SEARCH_COUNT},
    )
    response.raise_for_status()
    results = [
        result
        for result in response.json().get("results", [])
        if result.get("properties", {}).get("url", "").startswith("https://")
    ][:PROBE_COUNT]

    probes = await asyncio.gather(*(_probe(http, r["properties"]["url"]) for r in results))
    candidates = []
    for result, probe in zip(results, probes):
        if probe is None:
            continue
        width, height = probe if probe != UNKNOWN_SIZE else (None, None)
        candidates.append(
            Photo(image_url=result["properties"]["url"], title=result.get("title"), width=width, height=height)
        )

    # Results come back ranked: take the best vertical one that's big enough to pass
    # for a phone photo, else the best that loads (the app crops it to portrait).
    big_enough = [photo for photo in candidates if not photo.too_small]
    return next((photo for photo in big_enough if photo.is_portrait), None) or next(
        iter(big_enough or candidates), None
    )


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
