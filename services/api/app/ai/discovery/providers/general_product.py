"""General product discovery provider using Wikipedia + Wikidata.

Strategy:
- Wikipedia search + summary: primary source for product identification
- Wikidata SPARQL: barcode lookup only (fast indexed query, no text search)
- Structured attribute extraction from Wikipedia descriptions

Wikipedia covers millions of products, brands, and models across all commercial
domains. SPARQL text search is avoided because FILTER(CONTAINS) on unindexed
labels consistently times out on the Wikidata query service.
"""
from __future__ import annotations

import logging
import re
from urllib.parse import quote

import httpx

from app.ai.discovery.models import DiscoveryCandidate, DiscoveryQuery
from app.ai.discovery.query import normalize_query

logger = logging.getLogger(__name__)

_WIKIDATA_SPARQL_URL = "https://query.wikidata.org/sparql"
_WIKIPEDIA_SEARCH_URL = "https://en.wikipedia.org/w/api.php"
_WIKIPEDIA_SUMMARY_URL = "https://en.wikipedia.org/api/rest_v1/page/summary/{title}"
_SPARQL_TIMEOUT = 8.0
_WIKI_TIMEOUT = 12.0
_PROVIDER_NAME = "general_product"
_USER_AGENT = "VisionStockAI/2.0 (inventory-management; contact: admin@visionstock.app)"


async def search_general_products(query: DiscoveryQuery) -> list[DiscoveryCandidate]:
    """Search for products using Wikipedia search + Wikidata barcode lookup.

    Search priority:
    1. Barcode → Wikidata (fast indexed lookup)
    2. Brand + model → Wikipedia search + summary
    3. Model only → Wikipedia search + summary
    4. Brand + name → Wikipedia search + summary
    5. Any text → Wikipedia search + summary
    """
    nq = normalize_query(
        name=query.name,
        brand=query.brand,
        barcode=query.barcode,
        category=query.category,
        ocr_text=query.ocr_text,
        variant=query.variant,
        model_name=query.model_name,
    )
    candidates: list[DiscoveryCandidate] = []

    # 1. Barcode → Wikidata (fast indexed P2913 lookup)
    if query.barcode:
        candidates.extend(await _search_barcode_wikidata(query.barcode))

    # 2. Brand + model → Wikipedia (most specific, highest confidence)
    if nq.model_number and nq.brand:
        candidates.extend(
            await _search_wikipedia(f"{nq.brand} {nq.model_number}", nq.brand, nq.model_number)
        )

    # 3. Model only → Wikipedia
    if not candidates and nq.model_number:
        candidates.extend(
            await _search_wikipedia(nq.model_number, nq.brand, nq.model_number)
        )

    # 4. Brand + product name → Wikipedia
    if not candidates and nq.brand and nq.product_name:
        candidates.extend(
            await _search_wikipedia(f"{nq.brand} {nq.product_name}", nq.brand, nq.model_number)
        )

    # 5. Fallback: any available text → Wikipedia
    if not candidates:
        search_parts = [nq.brand, nq.product_name, nq.model_number]
        search_text = " ".join(p for p in search_parts if p)
        if search_text and len(search_text) >= 3:
            candidates.extend(
                await _search_wikipedia(search_text, nq.brand, nq.model_number)
            )

    return candidates


# ── Wikipedia Search ─────────────────────────────────────────────────────────


async def _search_wikipedia(
    search_text: str,
    brand: str | None = None,
    model: str | None = None,
) -> list[DiscoveryCandidate]:
    """Search Wikipedia articles by text, then fetch summaries for top results."""
    if not search_text or len(search_text.strip()) < 2:
        return []
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(_WIKI_TIMEOUT)) as client:
            resp = await client.get(
                _WIKIPEDIA_SEARCH_URL,
                params={
                    "action": "query",
                    "list": "search",
                    "srsearch": search_text.strip(),
                    "srlimit": "3",
                    "srinfo": "suggestion",
                    "format": "json",
                },
                headers={"User-Agent": _USER_AGENT},
            )
            if resp.status_code != 200:
                logger.debug("Wikipedia search returned %d for '%s'", resp.status_code, search_text)
                return []
            data = resp.json()
            results_list = data.get("query", {}).get("search", [])
            if not results_list:
                return []
            candidates: list[DiscoveryCandidate] = []
            # Fetch summaries concurrently for top results
            titles = [item.get("title", "") for item in results_list if item.get("title")]
            summaries = await asyncio.gather(
                *[_fetch_summary(client, t) for t in titles],
                return_exceptions=True,
            )
            for summary in summaries:
                if isinstance(summary, Exception) or summary is None:
                    continue
                # Score confidence based on query match
                summary["_query_text"] = search_text
                summary["_query_brand"] = brand
                summary["_query_model"] = model
                candidates.append(_summary_to_candidate(summary))
            return candidates
    except (httpx.HTTPError, ValueError, KeyError) as exc:
        logger.debug("Wikipedia search failed for '%s': %s", search_text, exc)
        return []


async def _fetch_summary(client: httpx.AsyncClient, title: str) -> dict | None:
    """Fetch a Wikipedia page summary. Returns None on failure."""
    if not title:
        return None
    try:
        resp = await client.get(
            _WIKIPEDIA_SUMMARY_URL.format(title=quote(title.replace(" ", "_"))),
            headers={"User-Agent": _USER_AGENT},
        )
        if resp.status_code != 200:
            return None
        data = resp.json()
        if data.get("type") in ("disambiguation", "not-found", "no-extract"):
            return None
        return data
    except (httpx.HTTPError, ValueError, KeyError):
        return None


import asyncio


def _summary_to_candidate(data: dict) -> DiscoveryCandidate:
    """Convert a Wikipedia summary response to a DiscoveryCandidate.

    Extracts structured attributes from the description text.
    """
    name = data.get("title", "")
    desc = data.get("extract", "")
    image = data.get("thumbnail", {}).get("source")
    page_url = data.get("content_urls", {}).get("desktop", {}).get("page")
    query_text = data.get("_query_text", "")
    query_brand = data.get("_query_brand")
    query_model = data.get("_query_model")

    # Extract structured attributes from description
    attrs = _extract_attributes(desc, name, query_brand)

    confidence = _compute_confidence(query_text, name, desc, query_brand, query_model)
    reason = _compute_match_reason(query_text, name, query_brand, query_model)

    return DiscoveryCandidate(
        name=name,
        brand=attrs.get("brand") or query_brand,
        category=attrs.get("category"),
        barcode=None,
        description=desc[:400] if desc else None,
        variant=attrs.get("variant"),
        model_name=query_model or attrs.get("model"),
        size=attrs.get("size"),
        weight=attrs.get("weight"),
        volume=attrs.get("volume"),
        image_url=image,
        source_url=page_url,
        manufacturer=attrs.get("manufacturer") or query_brand,
        sources=[_PROVIDER_NAME],
        confidence=round(confidence, 2),
        match_reason=reason,
    )


# ── Attribute Extraction ─────────────────────────────────────────────────────

# Weight patterns: "150 g", "150g", "1.5 kg", "1.5kg"
_RE_WEIGHT = re.compile(r"\b(\d+(?:[.,]\d+)?)\s+(g|kg|mg|lb|lbs|oz)\b", re.IGNORECASE)

# Volume patterns: "500 ml", "500ml", "1.5 l", "1.5l", "33 cl"
_RE_VOLUME = re.compile(r"\b(\d+(?:[.,]\d+)?)\s*(ml|mL|l|L|cl|dl|fl\s*oz|gallon)\b", re.IGNORECASE)

# Size patterns: "S/M/L/XL", "Size 10", numeric dimensions
_RE_SIZE = re.compile(r"\b(?:size\s*)?(XXS|XXL|XS|XL|XXL|S|M|L|2XL|3XL)\b", re.IGNORECASE)

# Capacity/quantity: "1000 mAh", "500 sheets", "10-pack"
_RE_CAPACITY = re.compile(r"\b(\d+)\s*(?:mAh|sheets|pack|pcs|pieces|count|ct)\b", re.IGNORECASE)

# Storage: "256GB", "256 GB", "1 TB", "512 GB"
_RE_STORAGE = re.compile(r"\b(\d+(?:[.,]\d+)?)\s*(GB|TB|MB)\b", re.IGNORECASE)

# Display: "6.5 inch", "6.5-inch", "6.5\""
_RE_DISPLAY = re.compile(r"\b(\d+(?:[.,]\d+)?)\s*(?:inch|in|\")\b", re.IGNORECASE)

# RAM: "8GB RAM", "16 GB"
_RE_RAM = re.compile(r"\b(\d+)\s*GB\s*(?:RAM|memory)\b", re.IGNORECASE)

# Battery: "5000 mAh"
_RE_BATTERY = re.compile(r"\b(\d+)\s*mAh\b", re.IGNORECASE)

# Category hints from description keywords
_CATEGORY_KEYWORDS = {
    "mobile phone": "Mobile Phones",
    "smartphone": "Mobile Phones",
    "tablet": "Tablets",
    "laptop": "Laptops",
    "notebook": "Laptops",
    "desktop": "Desktop Computers",
    "monitor": "Monitors",
    "television": "Televisions",
    "tv": "Televisions",
    "camera": "Cameras",
    "headphone": "Headphones",
    "earbuds": "Earbuds",
    "speaker": "Speakers",
    "smartwatch": "Smartwatches",
    "smart watch": "Smartwatches",
    "keyboard": "Keyboards",
    "mouse": "Mice",
    "printer": "Printers",
    "router": "Network Equipment",
    "ssd": "Storage",
    "hard drive": "Storage",
    "power drill": "Power Tools",
    "cordless drill": "Power Tools",
    "drill": "Power Tools",
    "saw": "Power Tools",
    "sander": "Power Tools",
    "grinder": "Power Tools",
    "vacuum": "Vacuum Cleaners",
    "blender": "Kitchen Appliances",
    "air fryer": "Kitchen Appliances",
    "toaster": "Kitchen Appliances",
    "microwave": "Kitchen Appliances",
    "refrigerator": "Refrigerators",
    "washer": "Washing Machines",
    "dryer": "Clothes Dryers",
    "shampoo": "Personal Care",
    "conditioner": "Personal Care",
    "deodorant": "Personal Care",
    "toothpaste": "Personal Care",
    "cosmetic": "Cosmetics",
    "makeup": "Cosmetics",
    "skincare": "Skincare",
    "vitamin": "Vitamins & Supplements",
    "supplement": "Vitamins & Supplements",
    "protein powder": "Vitamins & Supplements",
    "sneakers": "Footwear",
    "running shoes": "Footwear",
    "boots": "Footwear",
    "sandals": "Footwear",
    "jeans": "Clothing",
    "t-shirt": "Clothing",
    "jacket": "Clothing",
    "chair": "Furniture",
    "desk": "Furniture",
    "sofa": "Furniture",
}


def _extract_attributes(description: str, title: str, brand: str | None) -> dict:
    """Extract structured product attributes from Wikipedia description text."""
    text = f"{title} {description}"
    attrs: dict[str, str | None] = {}

    # Brand: if not already known, try to extract from title
    if not brand:
        first_word = title.split()[0] if title else ""
        if first_word and first_word[0].isupper() and len(first_word) >= 2:
            attrs["brand"] = first_word

    # Weight
    m = _RE_WEIGHT.search(text)
    if m:
        attrs["weight"] = f"{m.group(1)} {m.group(2)}"

    # Volume
    m = _RE_VOLUME.search(text)
    if m:
        attrs["volume"] = f"{m.group(1)} {m.group(2)}"

    # Size
    m = _RE_SIZE.search(text)
    if m:
        attrs["size"] = m.group(1).upper()

    # Storage (for electronics)
    m = _RE_STORAGE.search(text)
    if m:
        attrs["variant"] = f"{m.group(1)} {m.group(2)}"

    # Category
    lower_text = text.lower()
    for keyword, category in _CATEGORY_KEYWORDS.items():
        if keyword in lower_text:
            attrs["category"] = category
            break

    # Model: try to find model number in description
    if not attrs.get("model"):
        model_match = re.search(r"\b([A-Z]{1,4}[-\s]?\d{2,6}[A-Z]{0,4})\b", text)
        if model_match:
            attrs["model"] = model_match.group(1)

    return attrs


# ── Confidence Scoring ───────────────────────────────────────────────────────


def _compute_confidence(
    query_text: str,
    name: str,
    description: str,
    brand: str | None,
    model: str | None,
) -> float:
    """Score confidence based on how well the Wikipedia result matches the query.

    Priority: exact model+brand > exact model > brand+name > word overlap.
    """
    lower_query = query_text.lower().replace("_", " ")
    lower_name = name.lower()

    confidence = 0.3

    # Exact title match
    if lower_query == lower_name:
        confidence = 0.85
    elif lower_query in lower_name or lower_name in lower_query:
        confidence = 0.70
    else:
        # Word overlap scoring
        query_words = [w for w in lower_query.split() if len(w) >= 2]
        name_words = [w for w in lower_name.split() if len(w) >= 2]
        if query_words and name_words:
            overlap = sum(1 for w in query_words if w in name_words)
            ratio = overlap / len(query_words) if query_words else 0
            if ratio >= 0.8:
                confidence = 0.75
            elif ratio >= 0.5:
                confidence = 0.60
            elif overlap >= 1:
                confidence = 0.45

    # Boost: model number found in title — strong product identification
    if model and model.lower() in lower_name:
        confidence = max(confidence, 0.92)

    # Boost: brand in title AND model in title — very strong
    if brand and model and brand.lower() in lower_name and model.lower() in lower_name:
        confidence = max(confidence, 0.95)

    # Boost: brand matches exactly (first word)
    if brand and lower_name.split():
        first_word = lower_name.split()[0]
        if brand.lower() == first_word:
            confidence = max(confidence, 0.80)

    # Boost: brand in name
    if brand and brand.lower() in lower_name:
        confidence = max(confidence, max(confidence, 0.70))

    # Penalty: title is a person's name (likely false positive for product search)
    if _is_person_name(name):
        confidence = min(confidence, 0.35)

    # Penalty: title contains "list of" (likely a category page, not a product)
    if lower_name.startswith("list of"):
        confidence = min(confidence, 0.50)

    return confidence


def _is_person_name(name: str) -> bool:
    """Heuristic: check if a Wikipedia title looks like a person's name.

    Only flags short names (2-3 words) where every word is capitalized,
    no word is all-caps (acronyms), and no word looks like a product term.
    """
    _PRODUCT_WORDS = {
        "air", "max", "pro", "plus", "note", "galaxy", "iphone", "ipad",
        "macbook", "thinkpad", "surface", "pixel", "power", "cordless",
        "laser", "jet", "office", "windows", "linux", "swift", "ranger",
    }
    parts = name.strip().split()
    if len(parts) < 2 or len(parts) > 3:
        return False
    if any(p.lower() in _PRODUCT_WORDS for p in parts):
        return False
    return all(p[0].isupper() and not p.isupper() and len(p) >= 2 for p in parts)


def _compute_match_reason(
    query_text: str,
    name: str,
    brand: str | None,
    model: str | None,
) -> str:
    """Generate human-readable match reason."""
    lower_query = query_text.lower()
    lower_name = name.lower()

    parts: list[str] = []

    if model and model.lower() in lower_name:
        parts.append(f"exact model match ({model})")

    if brand and brand.lower() in lower_name:
        parts.append(f"brand match ({brand})")

    if lower_query == lower_name:
        parts.append("exact name match")
    elif lower_query in lower_name:
        parts.append("search term found in product name")
    elif lower_name in lower_query:
        parts.append("product name found in search")
    else:
        query_words = [w for w in lower_query.split() if len(w) >= 2]
        name_words = [w for w in lower_name.split() if len(w) >= 2]
        overlap = [w for w in query_words if w in name_words]
        if overlap:
            parts.append(f"word overlap ({', '.join(overlap[:3])})")

    return "; ".join(parts) if parts else "Wikipedia search match"


# ── Wikidata Barcode Lookup ──────────────────────────────────────────────────


async def _search_barcode_wikidata(barcode: str) -> list[DiscoveryCandidate]:
    """Fast barcode lookup via Wikidata SPARQL (indexed P2913 property)."""
    if not barcode or not barcode.strip():
        return []
    bc = barcode.strip()
    sparql = f"""
    SELECT ?item ?itemLabel ?brandLabel ?image ?description WHERE {{
      ?item wdt:P2913 "{bc}" .
      OPTIONAL {{ ?item wdt:P176 ?brandItem . ?brandItem rdfs:label ?brandLabel . FILTER(LANG(?brandLabel) = "en") }}
      OPTIONAL {{ ?item wdt:P18 ?image . }}
      OPTIONAL {{ ?item schema:description ?description . FILTER(LANG(?description) = "en") }}
      SERVICE wikibase:label {{ bd:serviceParam wikibase:language "en" . }}
    }}
    LIMIT 3
    """
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(_SPARQL_TIMEOUT)) as client:
            resp = await client.get(
                _WIKIDATA_SPARQL_URL,
                params={"query": sparql, "format": "json"},
                headers={
                    "User-Agent": _USER_AGENT,
                    "Accept": "application/sparql-results+json",
                },
            )
            if resp.status_code != 200:
                return []
            data = resp.json()
            bindings = data.get("results", {}).get("bindings", [])
            results: list[DiscoveryCandidate] = []
            for b in bindings:
                name = b.get("itemLabel", {}).get("value", "")
                if not name or name.startswith("Q"):
                    continue
                item_url = b.get("item", {}).get("value", "")
                wikidata_id = item_url.split("/")[-1] if "/" in item_url else ""
                brand_label = b.get("brandLabel", {}).get("value")
                description = b.get("description", {}).get("value")
                image = b.get("image", {}).get("value")
                page_url = f"https://www.wikidata.org/wiki/{wikidata_id}" if wikidata_id else None
                results.append(
                    DiscoveryCandidate(
                        name=name,
                        brand=brand_label,
                        barcode=bc,
                        description=description[:300] if description else None,
                        image_url=image,
                        source_url=page_url,
                        manufacturer=brand_label,
                        sources=[_PROVIDER_NAME],
                        confidence=0.90,
                        match_reason=f"barcode exact match ({bc}) via Wikidata",
                    )
                )
            return results
    except (httpx.HTTPError, ValueError, KeyError) as exc:
        logger.debug("Wikidata barcode lookup failed for %s: %s", bc, exc)
        return []
