import uuid
from datetime import datetime
from decimal import Decimal
from typing import Generic, TypeVar

from pydantic import BaseModel, ConfigDict, Field

T = TypeVar("T")


class Page(BaseModel, Generic[T]):
    items: list[T]
    total: int
    page: int
    page_size: int
    pages: int


class ActionResponse(BaseModel):
    status: str = "ok"


class CategoryIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    code: str | None = Field(default=None, max_length=40)
    parent_id: uuid.UUID | None = None


class CategoryUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    code: str | None = Field(default=None, max_length=40)
    parent_id: uuid.UUID | None = None
    status: str | None = Field(default=None, pattern="^(active|inactive)$")


class CategoryOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    store_id: uuid.UUID
    parent_id: uuid.UUID | None
    name: str
    code: str | None
    status: str
    created_at: datetime
    updated_at: datetime


class ProductIn(BaseModel):
    category_id: uuid.UUID | None = None
    name: str = Field(min_length=1, max_length=200)
    brand: str | None = Field(default=None, max_length=200)
    sku: str = Field(min_length=1, max_length=64)
    barcode: str | None = Field(default=None, max_length=64)
    description: str | None = Field(default=None, max_length=5000)
    unit: str = Field(min_length=1, max_length=20)
    cost_price: Decimal = Field(default=Decimal(0), ge=0, max_digits=14, decimal_places=2)
    selling_price: Decimal = Field(gt=0, max_digits=14, decimal_places=2)
    reorder_point: Decimal = Field(default=Decimal(0), ge=0, max_digits=12, decimal_places=3)
    reorder_quantity: Decimal = Field(default=Decimal(0), ge=0, max_digits=12, decimal_places=3)
    expiry_tracking_enabled: bool = False
    image_url: str | None = Field(default=None, max_length=500)


class ProductUpdate(BaseModel):
    category_id: uuid.UUID | None = None
    name: str | None = Field(default=None, min_length=1, max_length=200)
    brand: str | None = Field(default=None, max_length=200)
    sku: str | None = Field(default=None, min_length=1, max_length=64)
    barcode: str | None = Field(default=None, max_length=64)
    description: str | None = Field(default=None, max_length=5000)
    unit: str | None = Field(default=None, min_length=1, max_length=20)
    cost_price: Decimal | None = Field(default=None, ge=0, max_digits=14, decimal_places=2)
    selling_price: Decimal | None = Field(default=None, gt=0, max_digits=14, decimal_places=2)
    reorder_point: Decimal | None = Field(default=None, ge=0, max_digits=12, decimal_places=3)
    reorder_quantity: Decimal | None = Field(default=None, ge=0, max_digits=12, decimal_places=3)
    expiry_tracking_enabled: bool | None = None
    image_url: str | None = Field(default=None, max_length=500)
    status: str | None = Field(default=None, pattern="^(active|inactive)$")


class ProductOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    store_id: uuid.UUID
    category_id: uuid.UUID | None
    category_name: str | None = None
    sku: str
    barcode: str | None
    name: str
    brand: str | None = None
    description: str | None
    unit: str
    cost_price: Decimal
    selling_price: Decimal
    reorder_point: Decimal
    reorder_quantity: Decimal
    expiry_tracking_enabled: bool
    image_url: str | None
    status: str
    created_at: datetime
    updated_at: datetime


class ProductVisualProfileOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    product_id: uuid.UUID
    label: str
    reference_image_url: str | None
    model_version: str | None
    status: str
    created_at: datetime
    updated_at: datetime


class SupplierIn(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    contact_name: str | None = Field(default=None, max_length=120)
    phone: str | None = Field(default=None, max_length=32)
    email: str | None = Field(default=None, max_length=255)
    address: str | None = Field(default=None, max_length=2000)
    notes: str | None = Field(default=None, max_length=2000)


class SupplierUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    contact_name: str | None = Field(default=None, max_length=120)
    phone: str | None = Field(default=None, max_length=32)
    email: str | None = Field(default=None, max_length=255)
    address: str | None = Field(default=None, max_length=2000)
    notes: str | None = Field(default=None, max_length=2000)
    status: str | None = Field(default=None, pattern="^(active|inactive)$")


class SupplierOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    contact_name: str | None
    phone: str | None
    email: str | None
    address: str | None
    notes: str | None
    status: str
    created_at: datetime
    updated_at: datetime


class SupplierProductIn(BaseModel):
    product_id: uuid.UUID
    supplier_sku: str | None = Field(default=None, max_length=64)
    supplier_cost: Decimal | None = Field(default=None, ge=0, max_digits=14, decimal_places=2)
    lead_time_days: int | None = Field(default=None, ge=0, le=3650)
    is_preferred: bool = False


class SupplierProductUpdate(BaseModel):
    supplier_sku: str | None = Field(default=None, max_length=64)
    supplier_cost: Decimal | None = Field(default=None, ge=0, max_digits=14, decimal_places=2)
    lead_time_days: int | None = Field(default=None, ge=0, le=3650)
    is_preferred: bool | None = None


class SupplierProductOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    supplier_id: uuid.UUID
    product_id: uuid.UUID
    supplier_name: str | None = None
    product_name: str | None = None
    product_sku: str | None = None
    supplier_sku: str | None
    supplier_cost: Decimal | None
    lead_time_days: int | None
    is_preferred: bool
    created_at: datetime
    updated_at: datetime


class BarcodeEnrichment(BaseModel):
    """External product data retrieved for an unknown barcode."""

    barcode: str
    name: str | None = None
    brand: str | None = None
    category: str | None = None
    description: str | None = None
    image_url: str | None = None
    quantity: str | None = None
