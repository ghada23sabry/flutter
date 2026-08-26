"""Provider-based product discovery system.

Provides an extensible architecture for discovering product information
from multiple external sources.  Each provider implements a common
interface and returns normalised ``DiscoveryCandidate`` objects.

Providers:
- Open Food Facts: food and beverage products
- Open Beauty Facts: cosmetics, personal care, hygiene products
- General Product (Wikidata + Wikipedia): electronics, tools, appliances,
  hardware, household, office, automotive, industrial products

Usage::

    from app.ai.discovery import discover_from_all_providers, DiscoveryQuery
    result = await discover_from_all_providers(
        DiscoveryQuery(name="Samsung Galaxy A55", brand="Samsung"),
    )
"""
from app.ai.discovery.cache import DiscoveryCache, get_cache, make_cache_key
from app.ai.discovery.models import DiscoveryCandidate, DiscoveryQuery, DiscoveryResult
from app.ai.discovery.query import NormalizedQuery, classify_domain, normalize_query
from app.ai.discovery.registry import discover_from_all_providers
from app.ai.discovery.routing import select_providers

__all__ = [
    "DiscoveryCache",
    "DiscoveryCandidate",
    "DiscoveryQuery",
    "DiscoveryResult",
    "NormalizedQuery",
    "classify_domain",
    "discover_from_all_providers",
    "get_cache",
    "make_cache_key",
    "normalize_query",
    "select_providers",
]
