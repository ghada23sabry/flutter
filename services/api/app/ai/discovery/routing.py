"""Provider routing: intelligent provider selection based on product domain.

Routes discovery queries to the most appropriate providers based on:
- Product domain (food, beauty, electronics, tools, etc.)
- Available query data (barcode, model number, brand, etc.)
- Provider capabilities and availability

Never blindly calls every provider. Selects the optimal subset.
"""
from __future__ import annotations

from collections.abc import Awaitable, Callable

from app.ai.discovery.models import DiscoveryCandidate, DiscoveryQuery
from app.ai.discovery.providers.general_product import search_general_products
from app.ai.discovery.providers.open_beauty_facts import search_open_beauty_facts
from app.ai.discovery.providers.open_food_facts import search_open_food_facts

DiscoveryProviderFn = Callable[[DiscoveryQuery], Awaitable[list[DiscoveryCandidate]]]


def select_providers(query: DiscoveryQuery) -> list[tuple[str, DiscoveryProviderFn]]:
    """Select which providers to query and in what order.

    Returns list of (provider_name, provider_fn) tuples.
    Providers are ordered by relevance — most likely to succeed first.
    """
    from app.ai.discovery.query import normalize_query

    nq = normalize_query(
        name=query.name,
        brand=query.brand,
        barcode=query.barcode,
        category=query.category,
        ocr_text=query.ocr_text,
        variant=query.variant,
        model_name=query.model_name,
    )

    domain = nq.domain
    has_model = nq.model_number is not None
    has_brand = nq.brand is not None
    has_barcode = query.barcode is not None and query.barcode.strip() != ""

    providers: list[tuple[str, DiscoveryProviderFn]] = []

    if has_barcode:
        providers.append(("open_food_facts", search_open_food_facts))
        providers.append(("open_beauty_facts", search_open_beauty_facts))
        providers.append(("general_product", search_general_products))
        return providers

    if domain == "food":
        providers.append(("open_food_facts", search_open_food_facts))
        providers.append(("general_product", search_general_products))
    elif domain == "beauty":
        providers.append(("open_beauty_facts", search_open_beauty_facts))
        providers.append(("open_food_facts", search_open_food_facts))
        providers.append(("general_product", search_general_products))
    elif domain in ("electronics", "tools", "household"):
        providers.append(("general_product", search_general_products))
    elif has_model and has_brand:
        providers.append(("general_product", search_general_products))
        providers.append(("open_food_facts", search_open_food_facts))
    elif has_brand:
        providers.append(("general_product", search_general_products))
        providers.append(("open_food_facts", search_open_food_facts))
        providers.append(("open_beauty_facts", search_open_beauty_facts))
    else:
        providers.append(("general_product", search_general_products))
        providers.append(("open_food_facts", search_open_food_facts))
        providers.append(("open_beauty_facts", search_open_beauty_facts))

    return providers
