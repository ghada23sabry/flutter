"""External barcode enrichment via Open Food Facts.

Shared by the products router (manual lookup) and the AI resolution chain
(automatic enrichment during scan processing).  The lookup is best-effort:
missing products or network failures return empty fields, never raise.
"""

import logging
from dataclasses import dataclass

import httpx

logger = logging.getLogger(__name__)

_OFF_API_URL = "https://world.openfoodfacts.org/api/v2/product/{barcode}.json"
_OFF_TIMEOUT = 10.0


@dataclass(frozen=True)
class BarcodeEnrichmentResult:
    """Partial product information retrieved from an external source."""

    barcode: str
    name: str | None = None
    brand: str | None = None
    category: str | None = None
    description: str | None = None

    @property
    def has_name(self) -> bool:
        return bool(self.name)


async def enrich_barcode_off(barcode: str) -> BarcodeEnrichmentResult:
    """Look up product information for a barcode via Open Food Facts.

    Returns a result with whatever public data is available.  Missing products
    or network errors return an empty result (``name`` is ``None``) — callers
    decide how to handle partial data.
    """
    result = BarcodeEnrichmentResult(barcode=barcode)
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(_OFF_TIMEOUT)) as client:
            resp = await client.get(
                _OFF_API_URL.format(barcode=barcode),
                headers={"User-Agent": "VisionStockAI/1.0"},
            )
            if resp.status_code == 200:
                data = resp.json()
                product_data = data.get("product", {})
                if product_data:
                    result = BarcodeEnrichmentResult(
                        barcode=barcode,
                        name=product_data.get("product_name")
                        or product_data.get("product_name_en"),
                        brand=product_data.get("brands"),
                        category=product_data.get("categories"),
                        description=product_data.get("generic_name")
                        or product_data.get("generic_name_en"),
                    )
    except (httpx.HTTPError, ValueError, KeyError):
        logger.debug("Open Food Facts lookup failed for %s", barcode)
    return result
