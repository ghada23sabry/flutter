"""External product discovery via Open Food Facts text search.

When an AI detection cannot be matched to a catalog product, the discovery
service queries Open Food Facts' text search to find potential matches.
Returns structured candidates that the UI can present to the user for
review before creating a product.

No API key required — Open Food Facts is free and open.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field

import httpx

logger = logging.getLogger(__name__)

_OFF_SEARCH_URL = "https://world.openfoodfacts.org/cgi/search.pl"
_OFF_TIMEOUT = 10.0


@dataclass(frozen=True)
class ProductCandidate:
    """A product candidate discovered from an external source."""

    name: str
    brand: str | None = None
    category: str | None = None
    barcode: str | None = None
    description: str | None = None
    size: str | None = None
    image_url: str | None = None
    source: str = "open_food_facts"
    confidence: float = 0.0


@dataclass
class DiscoveryResult:
    """Results from an external product discovery search."""

    query: str
    candidates: list[ProductCandidate] = field(default_factory=list)
    source: str = "open_food_facts"
    error: str | None = None


async def search_products_off(
    query: str,
    *,
    max_results: int = 5,
) -> DiscoveryResult:
    """Search Open Food Facts by product name/brand text.

    Returns up to ``max_results`` candidates sorted by relevance.
    Failures are logged and return an empty result (never raise).
    """
    result = DiscoveryResult(query=query)
    if not query or not query.strip():
        return result

    search_term = query.strip()
    params = {
        "search_terms": search_term,
        "search_simple": 1,
        "action": "process",
        "json": 1,
        "page_size": max_results,
        "fields": "product_name,brands,categories,code,generic_name,image_front_url,quantity",
    }

    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(_OFF_TIMEOUT)) as client:
            resp = await client.get(
                _OFF_SEARCH_URL,
                params=params,
                headers={"User-Agent": "VisionStockAI/1.0"},
            )
            if resp.status_code != 200:
                result.error = f"HTTP {resp.status_code}"
                return result

            data = resp.json()
            products = data.get("products", [])
            if not products:
                return result

            for p in products:
                name = p.get("product_name") or p.get("product_name_en")
                if not name:
                    continue

                # Simple confidence heuristic: exact brand match boosts score.
                brand = p.get("brands")
                confidence = 0.5
                if brand and search_term.lower() in brand.lower():
                    confidence = 0.8
                if brand and search_term.lower() in name.lower():
                    confidence = max(confidence, 0.7)

                result.candidates.append(
                    ProductCandidate(
                        name=name.strip(),
                        brand=brand.strip() if brand else None,
                        category=p.get("categories"),
                        barcode=p.get("code"),
                        description=p.get("generic_name"),
                        size=p.get("quantity"),
                        image_url=p.get("image_front_url"),
                        confidence=round(confidence, 2),
                    )
                )
    except (httpx.HTTPError, ValueError, KeyError) as exc:
        logger.debug("Open Food Facts search failed for '%s': %s", search_term, exc)
        result.error = str(exc)

    return result


async def discover_product(
    name: str | None = None,
    brand: str | None = None,
    barcode: str | None = None,
    *,
    max_results: int = 5,
) -> DiscoveryResult:
    """High-level discovery: tries barcode first (fastest), then text search.

    Returns structured candidates the caller can present to the user.
    """
    # If we have a barcode, try direct lookup first (most specific).
    if barcode:
        from app.core.barcode_enrichment import enrich_barcode_off

        off = await enrich_barcode_off(barcode.strip())
        if off.has_name:
            return DiscoveryResult(
                query=barcode,
                candidates=[
                    ProductCandidate(
                        name=off.name or "",
                        brand=off.brand,
                        category=off.category,
                        barcode=off.barcode,
                        description=off.description,
                        source="open_food_facts",
                        confidence=0.9,
                    )
                ],
                source="open_food_facts",
            )

    # Text search: combine brand + name for better results.
    search_query = " ".join(filter(None, [brand, name]))
    if search_query:
        return await search_products_off(search_query, max_results=max_results)

    return DiscoveryResult(query=brand or name or "")
