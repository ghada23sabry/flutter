import uuid
from datetime import datetime
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

ScanStatus = Literal["processing", "needs_review", "confirmed", "cancelled", "completed", "failed"]

# Business operation: count replaces shelf quantities, receive adds detected
# quantities (PURCHASE movements), sale subtracts them (SALE movements).
ScanOperation = Literal["count", "receive", "sale"]

DetectionMethod = Literal["barcode", "visual", "ocr", "manual"]

DetectionStatus = Literal["accepted", "needs_review"]

ReconciliationStatus = Literal["no_change", "needs_review", "applied"]

ReconciliationResolution = Literal["apply", "ignore"]


# ── Scan sessions ────────────────────────────────────────────────────────────


class ScanSessionCreate(BaseModel):
    shelf_id: uuid.UUID | None = None
    operation: ScanOperation = "count"
    note: str | None = Field(default=None, max_length=500)


class ScanSessionOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    store_id: uuid.UUID
    shelf_id: uuid.UUID | None
    status: ScanStatus
    operation: ScanOperation
    note: str | None
    image_count: int
    started_by: uuid.UUID | None
    completed_by: uuid.UUID | None
    created_at: datetime
    updated_at: datetime
    completed_at: datetime | None


class ConfirmScanResponse(BaseModel):
    """Response from POST /ai/scans/{id}/confirm.

    Extends ScanSessionOut with the authoritative count of products whose
    inventory was actually mutated.  The client should use this count rather
    than deriving it from pre-confirm reconciliation snapshots.
    """

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    store_id: uuid.UUID
    shelf_id: uuid.UUID | None
    status: ScanStatus
    operation: ScanOperation
    note: str | None
    image_count: int
    started_by: uuid.UUID | None
    completed_by: uuid.UUID | None
    created_at: datetime
    updated_at: datetime
    completed_at: datetime | None
    products_updated: int = 0
    total_detections: int = 0
    unmatched_detections: int = 0


# ── Detections ───────────────────────────────────────────────────────────────


class DetectionIn(BaseModel):
    method: DetectionMethod
    image_key: str | None = Field(default=None, max_length=255)
    detected_sku: str | None = Field(default=None, max_length=64)
    detected_barcode: str | None = Field(default=None, max_length=64)
    product_id: uuid.UUID | None = None
    confidence: Decimal | None = Field(default=None, ge=0, le=1, max_digits=5, decimal_places=4)
    quantity_detected: Decimal = Field(gt=0, max_digits=12, decimal_places=3)
    meta: dict | None = None


class DetectionOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    session_id: uuid.UUID
    image_key: str | None
    method: DetectionMethod
    detected_sku: str | None
    detected_barcode: str | None
    product_id: uuid.UUID | None
    confidence: Decimal | None
    quantity_detected: Decimal
    status: DetectionStatus
    meta: dict | None
    created_by: uuid.UUID | None
    created_at: datetime
    product_name: str | None = None
    product_sku: str | None = None
    product_barcode: str | None = None


# ── Reconciliations ──────────────────────────────────────────────────────────


class DetectionLink(BaseModel):
    """Link an unmatched detection to an existing product.

    The product must exist within the same (tenant, store) scope as the scan
    session.  The server validates ownership, idempotency, and rebuilds the
    affected reconciliation row atomically.
    """

    product_id: uuid.UUID


class ReconciliationUpdate(BaseModel):
    """Review decision for one reconciliation row (M4-A.6).

    `resolution` decides whether the row is applied at confirmation (`apply`)
    or skipped (`ignore`). `detected_quantity` overrides the detected count and
    is only meaningful for `apply`. The server is authoritative — clients must
    not pre-validate; every value is re-validated here and again in the service.
    """

    resolution: ReconciliationResolution
    detected_quantity: Decimal | None = Field(default=None, ge=0, max_digits=12, decimal_places=3)

    @model_validator(mode="after")
    def _quantity_only_with_apply(self) -> "ReconciliationUpdate":
        if self.resolution == "ignore" and self.detected_quantity is not None:
            raise ValueError("detected_quantity is not allowed when a reconciliation is ignored")
        return self


class ReconciliationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    session_id: uuid.UUID
    product_id: uuid.UUID
    product_name: str | None = None
    sku: str | None = None
    detected_quantity: Decimal
    system_quantity: Decimal
    variance: Decimal
    status: ReconciliationStatus
    resolution: ReconciliationResolution | None
    confirmed_by: uuid.UUID | None
    confirmed_at: datetime | None
    created_at: datetime
    updated_at: datetime
