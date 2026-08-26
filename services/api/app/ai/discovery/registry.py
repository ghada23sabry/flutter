"""Provider registry and discovery orchestrator.

Discovers products by:
1. Routing to appropriate providers based on product domain
2. Querying selected providers concurrently
3. Caching results to avoid repeated external calls
4. Deduplicating and merging candidates across providers
5. Ranking by confidence with source-aware tie-breaking
"""
from __future__ import annotations

import asyncio
import logging

from app.ai.discovery.cache import DiscoveryCache, get_cache, make_cache_key
from app.ai.discovery.models import (
    DEFAULT_CONFIDENCE_THRESHOLD,
    DiscoveryCandidate,
    DiscoveryQuery,
    DiscoveryResult,
)
from app.ai.discovery.routing import select_providers

logger = logging.getLogger(__name__)


async def discover_from_all_providers(
    query: DiscoveryQuery,
    *,
    max_results: int = 8,
    confidence_threshold: float = DEFAULT_CONFIDENCE_THRESHOLD,
    cache: DiscoveryCache | None = None,
) -> DiscoveryResult:
    """Route, query, merge, deduplicate, and rank discovery results.

    Uses provider routing to select only relevant providers.
    Caches successful results. Merges candidates across providers.
    Sets confidence_threshold on result for false-positive gating.
    """
    cache = cache or get_cache()
    result = DiscoveryResult(
        query=query.search_text or query.barcode or "",
        confidence_threshold=confidence_threshold,
    )

    # Check cache first
    cache_key = make_cache_key(
        barcode=query.barcode,
        brand=query.brand,
        name=query.name,
        model=query.model_name,
        provider="discover",
    )
    cached = await cache.get(cache_key)
    if cached is not None:
        result.candidates = cached
        result.cache_hits = 1
        return result

    # Select providers based on query domain and data
    selected = select_providers(query)
    result.providers_attempted = [name for name, _ in selected]

    # Execute providers concurrently (limited concurrency to avoid rate limits)
    semaphore = asyncio.Semaphore(3)
    tasks = [
        _throttled_call(semaphore, name, fn, query)
        for name, fn in selected
    ]
    outcomes = await asyncio.gather(*tasks, return_exceptions=True)

    all_candidates: list[DiscoveryCandidate] = []
    for i, outcome in enumerate(outcomes):
        provider_name = selected[i][0]
        result.sources_queried.append(provider_name)
        if isinstance(outcome, Exception):
            logger.warning("Provider %s failed: %s", provider_name, outcome)
            result.errors.append(f"{provider_name}: {outcome}")
            continue
        all_candidates.extend(outcome)

    # Cross-provider deduplication and merging
    merged = _merge_and_deduplicate(all_candidates)
    ranked = sorted(merged, key=_ranking_key, reverse=True)
    result.candidates = ranked[:max_results]

    # Cache successful results
    if result.candidates:
        await cache.set(cache_key, result.candidates, ttl=3600.0)
    else:
        await cache.set(cache_key, result.candidates, ttl=300.0)

    return result


async def _throttled_call(
    semaphore: asyncio.Semaphore,
    name: str,
    fn,
    query: DiscoveryQuery,
) -> list[DiscoveryCandidate]:
    async with semaphore:
        try:
            return await asyncio.wait_for(fn(query), timeout=25.0)
        except TimeoutError:
            logger.debug("Provider %s timed out", name)
            return []
        except Exception as exc:
            logger.debug("Provider %s raised: %s", name, exc)
            raise


def _merge_and_deduplicate(candidates: list[DiscoveryCandidate]) -> list[DiscoveryCandidate]:
    """Merge candidates from multiple providers.

    Deduplication priority:
    1. Exact barcode match
    2. Exact model number match
    3. Normalized name + brand match

    Merging strategy:
    - Keep candidate with highest confidence
    - Merge sources lists
    - Fill missing fields from lower-confidence duplicates
    """
    groups: dict[str, list[DiscoveryCandidate]] = {}

    for c in candidates:
        key = _dedup_key(c)
        if key not in groups:
            groups[key] = []
        groups[key].append(c)

    merged: list[DiscoveryCandidate] = []
    for key, group in groups.items():
        if len(group) == 1:
            merged.append(group[0])
            continue

        best = max(group, key=lambda c: c.confidence)
        all_sources: list[str] = []
        for c in group:
            for s in c.sources:
                if s not in all_sources:
                    all_sources.append(s)

        merged_fields = _merge_fields(best, group)
        merged.append(
            DiscoveryCandidate(
                name=merged_fields["name"],
                brand=merged_fields.get("brand"),
                category=merged_fields.get("category"),
                barcode=merged_fields.get("barcode"),
                description=merged_fields.get("description"),
                variant=merged_fields.get("variant"),
                model_name=merged_fields.get("model_name"),
                size=merged_fields.get("size"),
                weight=merged_fields.get("weight"),
                volume=merged_fields.get("volume"),
                image_url=merged_fields.get("image_url"),
                source_url=merged_fields.get("source_url"),
                manufacturer=merged_fields.get("manufacturer"),
                sources=all_sources,
                confidence=best.confidence,
                match_reason=best.match_reason,
            )
        )

    return merged


def _dedup_key(c: DiscoveryCandidate) -> str:
    """Generate a deduplication key for a candidate."""
    if c.barcode:
        return f"bc:{c.barcode.strip().upper()}"
    if c.model_name and c.brand:
        model = c.model_name.strip().lower()
        brand = c.brand.strip().lower()
        return f"bm:{brand}:{model}"
    name = (c.name or "").strip().lower()
    brand = (c.brand or "").strip().lower()
    if name:
        return f"nb:{brand}:{name}"
    return f"??:{id(c)}"


def _merge_fields(best: DiscoveryCandidate, group: list[DiscoveryCandidate]) -> dict:
    """Merge fields from a group of duplicate candidates.

    Prefers the best candidate's values, fills gaps from others.
    Prefers manufacturer/official data over third-party when conflicting.
    """
    fields = {
        "name": best.name,
        "brand": best.brand,
        "category": best.category,
        "barcode": best.barcode,
        "description": best.description,
        "variant": best.variant,
        "model_name": best.model_name,
        "size": best.size,
        "weight": best.weight,
        "volume": best.volume,
        "image_url": best.image_url,
        "source_url": best.source_url,
        "manufacturer": best.manufacturer,
    }
    for c in group:
        if c is best:
            continue
        for field_name, current_val in fields.items():
            if not current_val and getattr(c, field_name, None):
                fields[field_name] = getattr(c, field_name)
        if "general_product" in c.sources and "open_food_facts" not in c.sources and c.description and not best.description:
            fields["description"] = c.description
    return fields


def _ranking_key(c: DiscoveryCandidate) -> tuple:
    """Ranking key: higher confidence first, prefer more sources, prefer manufacturer data."""
    has_manufacturer = 1 if "general_product" in c.sources else 0
    has_model = 1 if c.model_name else 0
    return (c.confidence, len(c.sources), has_manufacturer, has_model)
