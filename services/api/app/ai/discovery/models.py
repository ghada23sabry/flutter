"""Data models for the product discovery system."""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class DiscoveryQuery:
    """Inputs for a product discovery search."""

    name: str | None = None
    brand: str | None = None
    barcode: str | None = None
    category: str | None = None
    ocr_text: str | None = None
    variant: str | None = None
    model_name: str | None = None
    selling_price: str | None = None

    @property
    def search_text(self) -> str:
        """Best text query built from available fields."""
        parts = [self.brand, self.name, self.model_name, self.variant]
        return " ".join(p for p in parts if p).strip()

    @property
    def has_model(self) -> bool:
        return bool(self.model_name and self.model_name.strip())

    @property
    def has_barcode(self) -> bool:
        return bool(self.barcode and self.barcode.strip())


# Default confidence threshold: results below this are "possible" not "confirmed".
DEFAULT_CONFIDENCE_THRESHOLD = 0.65


@dataclass(frozen=True)
class DiscoveryCandidate:
    """A single product candidate discovered from an external source."""

    name: str
    brand: str | None = None
    category: str | None = None
    barcode: str | None = None
    description: str | None = None
    variant: str | None = None
    model_name: str | None = None
    size: str | None = None
    weight: str | None = None
    volume: str | None = None
    image_url: str | None = None
    source_url: str | None = None
    manufacturer: str | None = None
    sources: list[str] = field(default_factory=list)
    confidence: float = 0.0
    match_reason: str = ""

    @property
    def source(self) -> str:
        """Primary source (first in list, or 'unknown')."""
        return self.sources[0] if self.sources else "unknown"

    def is_confident(self, threshold: float = DEFAULT_CONFIDENCE_THRESHOLD) -> bool:
        """Whether this candidate exceeds the confidence threshold."""
        return self.confidence >= threshold


@dataclass
class DiscoveryResult:
    """Aggregated result from one or more discovery providers."""

    query: str
    candidates: list[DiscoveryCandidate] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    sources_queried: list[str] = field(default_factory=list)
    providers_attempted: list[str] = field(default_factory=list)
    cache_hits: int = 0
    confidence_threshold: float = DEFAULT_CONFIDENCE_THRESHOLD

    @property
    def best_candidate(self) -> DiscoveryCandidate | None:
        """The highest-confidence candidate above the threshold, if any."""
        for c in self.candidates:
            if c.is_confident(self.confidence_threshold):
                return c
        return None

    @property
    def has_confident_match(self) -> bool:
        """Whether any candidate exceeds the confidence threshold."""
        return self.best_candidate is not None
