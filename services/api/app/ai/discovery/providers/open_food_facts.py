"""Open Food Facts discovery provider.

Searches food and beverage products via the Open Food Facts API.
Works with both barcode lookups and text searches.
"""
from __future__ import annotations

import logging

import httpx

from app.ai.discovery.models import DiscoveryCandidate, DiscoveryQuery

logger = logging.getLogger(__name__)

_OFF_SEARCH_URL = "https://world.openfoodfacts.org/cgi/search.pl"
_OFF_PRODUCT_URL = "https://world.openfoodfacts.org/api/v2/product/{barcode}.json"
_OFF_TIMEOUT = 10.0
_PROVIDER_NAME = "open_food_facts"


async def search_open_food_facts(query: DiscoveryQuery) -> list[DiscoveryCandidate]:
    """Search Open Food Facts using barcode (if available) or text search."""
    candidates: list[DiscoveryCandidate] = []

    if query.barcode:
        barcode_candidates = await _lookup_barcode(query.barcode)
        candidates.extend(barcode_candidates)

    search_text = query.search_text
    if search_text:
        text_candidates = await _search_text(search_text)
        candidates.extend(text_candidates)

    return candidates


async def _lookup_barcode(barcode: str) -> list[DiscoveryCandidate]:
    """Direct barcode lookup on Open Food Facts."""
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(_OFF_TIMEOUT)) as client:
            resp = await client.get(
                _OFF_PRODUCT_URL.format(barcode=barcode.strip()),
                headers={"User-Agent": "VisionStockAI/2.0"},
            )
            if resp.status_code != 200:
                return []
            data = resp.json()
            product = data.get("product")
            if not product:
                return []
            return [_build_candidate(product, barcode=barcode, confidence=0.9, reason="barcode exact match")]
    except (httpx.HTTPError, ValueError, KeyError) as exc:
        logger.debug("OFF barcode lookup failed for %s: %s", barcode, exc)
        return []


async def _search_text(search_text: str) -> list[DiscoveryCandidate]:
    """Text search on Open Food Facts."""
    params = {
        "search_terms": search_text,
        "search_simple": 1,
        "action": "process",
        "json": 1,
        "page_size": 5,
        "fields": "product_name,brands,categories,code,generic_name,image_front_url,quantity,ingredients_text",
    }
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(_OFF_TIMEOUT)) as client:
            resp = await client.get(
                _OFF_SEARCH_URL,
                params=params,
                headers={"User-Agent": "VisionStockAI/2.0"},
            )
            if resp.status_code != 200:
                return []
            data = resp.json()
            products = data.get("products", [])
            results: list[DiscoveryCandidate] = []
            for p in products:
                name = p.get("product_name") or p.get("product_name_en")
                if not name:
                    continue
                brand = p.get("brands")
                confidence = _compute_confidence(search_text, name, brand)
                reason = _build_match_reason(search_text, name, brand)
                results.append(_build_candidate(p, confidence=confidence, reason=reason))
            return results
    except (httpx.HTTPError, ValueError, KeyError) as exc:
        logger.debug("OFF text search failed for '%s': %s", search_text, exc)
        return []


def _build_candidate(
    product: dict,
    *,
    barcode: str | None = None,
    confidence: float = 0.5,
    reason: str = "",
) -> DiscoveryCandidate:
    name = product.get("product_name") or product.get("product_name_en") or ""
    brand = product.get("brands")
    categories = product.get("categories")
    return DiscoveryCandidate(
        name=name.strip(),
        brand=brand.strip() if brand else None,
        category=categories.strip() if categories else None,
        barcode=barcode or product.get("code"),
        description=product.get("generic_name"),
        size=product.get("quantity"),
        image_url=product.get("image_front_url"),
        manufacturer=brand.strip() if brand else None,
        sources=[_PROVIDER_NAME],
        confidence=round(confidence, 2),
        match_reason=reason,
    )


def _compute_confidence(search_text: str, name: str, brand: str | None) -> float:
    lower_search = search_text.lower()
    lower_name = name.lower()
    confidence = 0.5
    if brand and lower_search in brand.lower():
        confidence = max(confidence, 0.8)
    if lower_search in lower_name or lower_name in lower_search:
        confidence = max(confidence, 0.7)
    search_words = [w for w in lower_search.split() if len(w) >= 2]
    name_words = [w for w in lower_name.split() if len(w) >= 2]
    if search_words and name_words:
        overlap = sum(1 for w in search_words if w in name_words)
        if overlap >= 2:
            confidence = max(confidence, 0.75)
    return confidence


def _build_match_reason(search_text: str, name: str, brand: str | None) -> str:
    reasons: list[str] = []
    if brand and search_text.lower() in brand.lower():
        reasons.append(f"brand match ({brand})")
    lower_name = name.lower()
    lower_search = search_text.lower()
    if lower_search in lower_name:
        reasons.append("name contains search term")
    elif lower_name in lower_search:
        reasons.append("search contains product name")
    else:
        search_words = [w for w in lower_search.split() if len(w) >= 2]
        name_words = [w for w in lower_name.split() if len(w) >= 2]
        overlap = [w for w in search_words if w in name_words]
        if overlap:
            reasons.append(f"word overlap ({', '.join(overlap[:3])})")
    return "; ".join(reasons) if reasons else "text similarity"
