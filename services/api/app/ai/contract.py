"""Typed contract shared by vision adapters and the business/service layer.

The adapter is pure perception: it maps image bytes + scan context to a list of
typed detections. It has NO access to sessions, products, or inventory — product
identity resolution (sku/barcode → product) and any inventory change are the
service layer's job (M4-A.3), which structurally prevents the vision adapter
from ever mutating stock.
"""
import uuid
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

# Same vocabulary as app.schemas.ai.DetectionMethod — kept standalone here so the
# adapter contract does not depend on the API schema layer.
VisionMethod = Literal["barcode", "visual", "ocr", "manual"]


class VisionContext(BaseModel):
    """Immutable scan context. Used by the real adapter (M4-B) to scope
    store-aware inference; the mock intentionally ignores it."""

    model_config = ConfigDict(frozen=True)

    tenant_id: uuid.UUID
    store_id: uuid.UUID
    shelf_id: uuid.UUID | None = None


class DetectedItem(BaseModel):
    """One perceived item on the image: how it was read, what was read, and how
    confident the read is. `confidence` is None only for manual entries; machine
    methods (barcode/visual/ocr) must always carry a score in [0, 1]."""

    model_config = ConfigDict(frozen=True)

    method: VisionMethod
    detected_sku: str | None = None
    detected_barcode: str | None = None
    confidence: Decimal | None = Field(default=None, ge=0, le=1, max_digits=5, decimal_places=4)
    quantity: Decimal = Field(gt=0, max_digits=12, decimal_places=3)
    meta: dict | None = None

    @model_validator(mode="after")
    def _confidence_by_method(self) -> "DetectedItem":
        if self.method == "manual" and self.confidence is not None:
            raise ValueError("manual detections must not carry a confidence score")
        if self.method != "manual" and self.confidence is None:
            raise ValueError(f"{self.method} detections require a confidence score in [0, 1]")
        return self
