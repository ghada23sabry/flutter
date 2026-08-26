"""Async TTL cache for discovery queries.

Avoids repeated external API calls for the same product.
Keys are normalised to prevent duplicate lookups for equivalent queries.
"""
from __future__ import annotations

import asyncio
import hashlib
import logging
import time
from typing import Any

logger = logging.getLogger(__name__)

_DEFAULT_TTL = 3600.0  # 1 hour
_NEGATIVE_TTL = 300.0  # 5 min for "no result" caches


class DiscoveryCache:
    """Simple async-safe in-memory TTL cache."""

    def __init__(self, ttl: float = _DEFAULT_TTL) -> None:
        self._ttl = ttl
        self._store: dict[str, tuple[float, Any]] = {}
        self._lock = asyncio.Lock()

    async def get(self, key: str) -> Any | None:
        async with self._lock:
            entry = self._store.get(key)
            if entry is None:
                return None
            expires, value = entry
            if time.monotonic() > expires:
                del self._store[key]
                return None
            return value

    async def set(self, key: str, value: Any, ttl: float | None = None) -> None:
        effective_ttl = ttl if ttl is not None else self._ttl
        async with self._lock:
            self._store[key] = (time.monotonic() + effective_ttl, value)

    async def invalidate_prefix(self, prefix: str) -> int:
        async with self._lock:
            keys_to_delete = [k for k in self._store if k.startswith(prefix)]
            for k in keys_to_delete:
                del self._store[k]
            return len(keys_to_delete)

    @property
    def size(self) -> int:
        return len(self._store)


# Module-level singleton
_cache: DiscoveryCache | None = None


def get_cache() -> DiscoveryCache:
    global _cache
    if _cache is None:
        _cache = DiscoveryCache()
    return _cache


def make_cache_key(
    *,
    barcode: str | None = None,
    brand: str | None = None,
    name: str | None = None,
    model: str | None = None,
    provider: str = "",
) -> str:
    """Build a deterministic cache key from query fields."""
    parts = [
        f"bc:{barcode.strip().upper()}" if barcode else "",
        f"br:{brand.strip().lower()}" if brand else "",
        f"nm:{name.strip().lower()}" if name else "",
        f"md:{model.strip().upper()}" if model else "",
    ]
    raw = "|".join(p for p in parts if p)
    h = hashlib.sha256(raw.encode()).hexdigest()[:16]
    return f"{provider}:{h}" if provider else h
