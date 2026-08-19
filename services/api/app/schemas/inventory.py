import uuid
from datetime import date, datetime
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

MovementType = Literal["OPENING", "ADJUSTMENT", "COUNT", "SALE", "PURCHASE", "RETURN", "TRANSFER", "WRITE_OFF"]

StockStatus = Literal["healthy", "low_stock", "out_of_stock"]

ExpiryStatus = Literal["expired", "near_expiry", "normal"]


# ── Layout: zones / shelves / shelf↔product mapping ─────────────────────────


class ZoneIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    code: str | None = Field(default=None, max_length=40)


class ZoneUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    code: str | None = Field(default=None, max_length=40)
    status: str | None = Field(default=None, pattern="^(active|inactive)$")


class ZoneOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    store_id: uuid.UUID
    name: str
    code: str | None
    status: str
    created_at: datetime
    updated_at: datetime


class ShelfIn(BaseModel):
    zone_id: uuid.UUID
    label: str = Field(min_length=1, max_length=120)
    code: str | None = Field(default=None, max_length=40)
    position: int = Field(default=0, ge=0, le=100000)


class ShelfUpdate(BaseModel):
    zone_id: uuid.UUID | None = None
    label: str | None = Field(default=None, min_length=1, max_length=120)
    code: str | None = Field(default=None, max_length=40)
    position: int | None = Field(default=None, ge=0, le=100000)
    status: str | None = Field(default=None, pattern="^(active|inactive)$")


class ShelfOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    store_id: uuid.UUID
    zone_id: uuid.UUID
    label: str
    code: str | None
    position: int
    status: str
    created_at: datetime
    updated_at: datetime


class ShelfWithZoneOut(ShelfOut):
    zone_name: str | None = None


class ShelfProductMapIn(BaseModel):
    product_id: uuid.UUID
    position: int = Field(default=0, ge=0, le=100000)
    is_primary: bool = False


class ShelfProductMapOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    shelf_id: uuid.UUID
    product_id: uuid.UUID
    position: int
    is_primary: bool
    product_name: str | None = None
    sku: str | None = None
    barcode: str | None = None


# ── Inventory ────────────────────────────────────────────────────────────────


class OpeningStockIn(BaseModel):
    quantity: Decimal = Field(gt=0, max_digits=12, decimal_places=3)
    batch_code: str | None = Field(default=None, max_length=64)
    expiry_date: date | None = None


class AdjustmentIn(BaseModel):
    """One adjustment target is required: absolute `new_quantity` OR signed `delta`.

    `delta` is applied relative to the locked current quantity, which makes
    concurrent stock-in/stock-out adjustments additive (no lost updates).
    """

    new_quantity: Decimal | None = Field(default=None, ge=0, max_digits=12, decimal_places=3)
    delta: Decimal | None = Field(default=None, max_digits=12, decimal_places=3)
    reason: str = Field(min_length=1, max_length=500)
    expiry_batch_id: uuid.UUID | None = None
    reference_type: str | None = Field(default=None, max_length=30)
    reference_id: str | None = Field(default=None, max_length=64)
    movement_type: MovementType = "ADJUSTMENT"

    @model_validator(mode="after")
    def _exactly_one_target(self) -> "AdjustmentIn":
        if (self.new_quantity is None) == (self.delta is None):
            raise ValueError("Provide exactly one of new_quantity or delta")
        return self


class InventoryOut(BaseModel):
    product_id: uuid.UUID
    product_name: str
    sku: str
    barcode: str | None
    unit: str
    category_name: str | None
    cost_price: Decimal
    reorder_point: Decimal
    reorder_quantity: Decimal
    expiry_tracking_enabled: bool
    quantity: Decimal
    reserved_quantity: Decimal
    available_quantity: Decimal
    stock_status: StockStatus
    value: Decimal
    nearest_expiry_date: date | None = None
    nearest_expiry_status: ExpiryStatus | None = None
    updated_at: datetime


class InventorySummaryOut(BaseModel):
    total_products: int
    total_value: Decimal
    healthy: int
    low_stock: int
    out_of_stock: int
    near_expiry: int
    expired: int


class ProductStockOut(BaseModel):
    product_id: uuid.UUID
    product_name: str
    sku: str
    barcode: str | None
    unit: str
    category_id: uuid.UUID | None
    category_name: str | None
    cost_price: Decimal
    selling_price: Decimal
    reorder_point: Decimal
    reorder_quantity: Decimal
    expiry_tracking_enabled: bool
    quantity: Decimal
    reserved_quantity: Decimal
    available_quantity: Decimal
    stock_status: StockStatus
    value: Decimal
    has_opening: bool
    shelves: list[ShelfWithZoneOut] = []
    expiry_batches: list["ExpiryBatchOut"] = []
    recent_movements: list["StockMovementOut"] = []


class StockMovementOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    product_id: uuid.UUID
    product_name: str | None = None
    sku: str | None = None
    quantity_delta: Decimal
    resulting_quantity: Decimal | None
    movement_type: MovementType
    reference_type: str | None
    reference_id: str | None
    notes: str | None
    created_by: uuid.UUID | None
    created_by_name: str | None = None
    created_at: datetime


class ExpiryBatchIn(BaseModel):
    product_id: uuid.UUID
    quantity: Decimal = Field(gt=0, max_digits=12, decimal_places=3)
    expiry_date: date
    batch_code: str | None = Field(default=None, max_length=64)


class ExpiryBatchUpdate(BaseModel):
    batch_code: str | None = Field(default=None, max_length=64)
    expiry_date: date | None = None


class ExpiryBatchWriteOffIn(BaseModel):
    """Write off expired stock from a batch (WRITE_OFF ledger movement)."""

    quantity: Decimal = Field(gt=0, max_digits=12, decimal_places=3)
    reason: str = Field(min_length=1, max_length=500)


class ExpiryBatchOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    product_id: uuid.UUID
    product_name: str | None = None
    sku: str | None = None
    barcode: str | None = None
    batch_code: str | None
    quantity: Decimal
    expiry_date: date
    received_at: datetime
    created_at: datetime
    updated_at: datetime
    status: ExpiryStatus = "normal"
    days_remaining: int = 0
    value: Decimal = Decimal(0)


ProductStockOut.model_rebuild()
