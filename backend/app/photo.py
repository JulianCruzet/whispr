import asyncio
import logging
from dataclasses import dataclass

import anthropic
import httpx
from PIL import ImageFile

from app.config import ASSETS_DIR, FALLBACK_PHOTO, Settings
from app.jev import JEV_URL

log = logging.getLogger(__name__)

BRAVE_IMAGES_URL = "https://api.search.brave.com/res/v1/images/search"
# Ask for plenty: most search photos are landscape, and we want one that looks shot on a phone.
SEARCH_COUNT = 20
# Top results checked at once. Each is read only until its size is known.
PROBE_COUNT = 10
# A host that slow would make the phone wait too; the other results answer well within it.
PROBE_TIMEOUT_S = 1.5
# Enough to reach the size in any JPEG, PNG or WebP header, even behind a big EXIF block.
MAX_PROBE_BYTES = 512 * 1024
# At least this much taller than wide counts as a vertical phone photo.
PORTRAIT_RATIO = 1.15
# Smaller than this on the short side looks like a thumbnail, not a phone photo.
MIN_SHORT_SIDE = 400
# Jev reads only text, so it ranks results by their title and source page; then Haiku,
# which can see, looks at the top few. A photo it rejects is never sent.
# Runs alongside the size checks, so it gets the same time they do.
JEV_RANK_TIMEOUT_S = 1.5
LOOK_COUNT = 3
# Stock and press agencies: their photos are posed or shot from the press pit, never what
# a fan took on their phone, and Haiku sometimes let one through (a Getty shot of Drake
# with a mic in front of a backdrop). Results from these sites are never used.
PRESS_SITES = (
    "gettyimages.",
    "shutterstock.",
    "alamy.",
    "istockphoto.",
    "stock.adobe.",
    "dreamstime.",
    "depositphotos.",
    "123rf.",
    "wireimage.",
    "apimages.",
    "reuters.",
    "zumapress.",
    "imago-images.",
)


def _from_press_site(result: dict) -> bool:
    """True if a search result's image or page is on a stock or press photo site."""
    where = " ".join(
        str(part).lower()
        for part in (result.get("properties", {}).get("url"), result.get("url"), result.get("source"))
        if part
    )
    return any(site in where for site in PRESS_SITES)

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


async def _rank_by_jev(
    http: httpx.AsyncClient, settings: Settings, query: str, results: list[dict]
) -> list[dict]:
    """Results reordered by how likely each is a real photo of this event, judged by Jev
    from its title and source page. Falls back to Brave's order if Jev can't answer."""
    if not settings.jev_api_key or len(results) < 2:
        return results
    criteria = {
        f"r{i}": f"{result.get('title') or 'untitled'} (from {result.get('source') or result.get('url') or 'unknown site'})"[:200]
        for i, result in enumerate(results)
    }
    body = {
        "model": settings.jev_model,
        "state": f"Image search for: {query}",
        "questions": {
            "best_photo": {
                "type": "choice",
                "instructions": (
                    "Which result is most likely a real photo of exactly this event, taken by "
                    "someone in the audience? Not a press photo, red carpet, poster, meme, "
                    "album art or a different event."
                ),
                "criteria": criteria,
            }
        },
    }
    try:
        response = await http.post(
            JEV_URL,
            headers={"Authorization": f"Bearer {settings.jev_api_key}"},
            json=body,
            timeout=JEV_RANK_TIMEOUT_S,
        )
        response.raise_for_status()
        probabilities = response.json()["answers"]["best_photo"]["probabilities"]
        scores = [float(probabilities.get(f"r{i}", 0)) for i in range(len(results))]
    except (httpx.HTTPError, KeyError, TypeError, ValueError) as exc:
        log.info("Jev couldn't rank the photos, keeping search order: %r", exc)
        return results
    order = sorted(range(len(results)), key=lambda i: -scores[i])  # stable: ties keep search order
    return [results[i] for i in order]


async def _looks_right(
    claude: anthropic.AsyncAnthropic, settings: Settings, query: str, image_url: str
) -> bool | None:
    """Haiku looks at the image: True if it shows the event, False if clearly not,
    None if it couldn't tell (then the photo is still allowed)."""
    try:
        response = await claude.messages.create(
            model=settings.whisper_model,
            max_tokens=5,
            thinking={"type": "disabled"},
            output_config={"effort": "low"},
            messages=[
                {
                    "role": "user",
                    "content": [
                        {"type": "image", "source": {"type": "url", "url": image_url}},
                        {
                            "type": "text",
                            "text": (
                                f"Could a fan have taken this photo on their phone at {query}? "
                                "Answer yes only if it shows the event itself from the audience: "
                                "a stage, stage lights or a crowd in view. Answer no for a press "
                                "photo, a posed or studio shot, a red carpet, a press conference, "
                                "a person in front of a plain backdrop or banner, a poster, a meme "
                                "or a different event. Answer only yes or no."
                            ),
                        },
                    ],
                }
            ],
        )
    except anthropic.APIError as exc:
        log.info("Couldn't check the photo, allowing it: %r", exc)
        return None
    answer = "".join(block.text for block in response.content if block.type == "text").strip().lower()
    if answer.startswith("yes"):
        return True
    if answer.startswith("no"):
        return False
    return None


async def _search(
    http: httpx.AsyncClient,
    settings: Settings,
    query: str,
    claude: anthropic.AsyncAnthropic | None = None,
) -> Photo | None:
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
        and not _from_press_site(result)
    ][:PROBE_COUNT]
    # Jev's ranking and the size checks each need only the search results, so run them together.
    ranked, probes = await asyncio.gather(
        _rank_by_jev(http, settings, query, results),
        asyncio.gather(*(_probe(http, r["properties"]["url"]) for r in results)),
    )
    size_of = {id(result): probe for result, probe in zip(results, probes)}
    candidates: list[tuple[Photo, str]] = []
    for result in ranked:
        probe = size_of[id(result)]
        if probe is None:
            continue
        width, height = probe if probe != UNKNOWN_SIZE else (None, None)
        photo = Photo(image_url=result["properties"]["url"], title=result.get("title"), width=width, height=height)
        # Brave's own small copy always loads, so Haiku looks at that one.
        candidates.append((photo, result.get("thumbnail", {}).get("src") or photo.image_url))

    # Best first: vertical ones big enough to pass for a phone photo, then other big ones,
    # then the rest (the app crops anything wide to portrait). Within each, Jev's order.
    big_enough = [c for c in candidates if not c[0].too_small]
    preferred = [c for c in big_enough if c[0].is_portrait] + [c for c in big_enough if not c[0].is_portrait]
    preferred += [c for c in candidates if c not in big_enough]
    if claude is None or not preferred:
        return preferred[0][0] if preferred else None

    # Haiku looks at the top few at once, and the best one it doesn't reject goes out as soon
    # as its answer is in, without waiting on the others.
    looked = preferred[:LOOK_COUNT]
    looks = [asyncio.create_task(_looks_right(claude, settings, query, thumb)) for _, thumb in looked]
    try:
        for (photo, _), look in zip(looked, looks):
            if await look is not False:
                return photo
    finally:
        for look in looks:
            look.cancel()
    log.info("Haiku rejected the top %d photos for %r", len(looked), query)
    return None


def fallback_photo(settings: Settings) -> Photo | None:
    if settings.fallback_photo_url:
        image_url = settings.fallback_photo_url
    elif (ASSETS_DIR / FALLBACK_PHOTO).is_file():
        image_url = f"{settings.base_url}/assets/{FALLBACK_PHOTO}"
    else:
        log.error("No FALLBACK_PHOTO_URL and no cached photo at %s", ASSETS_DIR / FALLBACK_PHOTO)
        return None
    return Photo(image_url=image_url, used_fallback=True)


async def find_photo(
    http: httpx.AsyncClient,
    settings: Settings,
    query: str,
    use_cached: bool = True,
    claude: anthropic.AsyncAnthropic | None = None,
) -> Photo | None:
    photo = None
    if settings.brave_search_api_key:
        try:
            async with asyncio.timeout(settings.photo_deadline_s):
                photo = await _search(http, settings, query, claude)
        except (TimeoutError, httpx.HTTPError, ValueError) as exc:
            log.warning("Photo search failed: %r", exc)
    else:
        log.warning("No BRAVE_SEARCH_API_KEY, so no photo search")
    return photo or (fallback_photo(settings) if use_cached else None)
