import uuid
from datetime import UTC, date, datetime
from decimal import Decimal

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.db import Base

# Shared stock-movement vocabulary (M3 active: OPENING + ADJUSTMENT; future
# domains add SALE/PURCHASE/RETURN/TRANSFER/COUNT — the ledger stays unified).
MOVEMENT_TYPES = {"OPENING", "ADJUSTMENT", "COUNT", "SALE", "PURCHASE", "RETURN", "TRANSFER", "WRITE_OFF"}

STOCK_STATUS_HEALTHY = "healthy"
STOCK_STATUS_LOW = "low_stock"
STOCK_STATUS_OUT = "out_of_stock"

EXPIRY_STATUS_EXPIRED = "expired"
EXPIRY_STATUS_NEAR = "near_expiry"
EXPIRY_STATUS_NORMAL = "normal"


def _utcnow() -> datetime:
    return datetime.now(UTC)


class Zone(Base):
    __tablename__ = "zones"
    __table_args__ = (
        UniqueConstraint("store_id", "code", name="uq_zones_store_code"),
        Index("ix_zones_store_name", "store_id", "name"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenants.id", ondelete="CASCADE"), index=True)
    store_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("stores.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(120))
    code: Mapped[str | None] = mapped_column(String(40))
    status: Mapped[str] = mapped_column(String(20), default="active")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow, onupdate=_utcnow, server_default=func.now()
    )

    shelves: Mapped[list["Shelf"]] = relationship(back_populates="zone", cascade="all, delete-orphan")


class Shelf(Base):
    __tablename__ = "shelves"
    __table_args__ = (
        UniqueConstraint("store_id", "code", name="uq_shelves_store_code"),
        Index("ix_shelves_store_zone", "store_id", "zone_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenants.id", ondelete="CASCADE"), index=True)
    store_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("stores.id", ondelete="CASCADE"), index=True)
    zone_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("zones.id", ondelete="CASCADE"), index=True)
    label: Mapped[str] = mapped_column(String(120))
    code: Mapped[str | None] = mapped_column(String(40))
    position: Mapped[int] = mapped_column(Integer, default=0)
    status: Mapped[str] = mapped_column(String(20), default="active")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow, onupdate=_utcnow, server_default=func.now()
    )

    zone: Mapped[Zone] = relationship(back_populates="shelves")
    product_links: Mapped[list["ShelfProductMap"]] = relationship(
        back_populates="shelf", cascade="all, delete-orphan"
    )


class ShelfProductMap(Base):
    __tablename__ = "shelf_product_map"
    __table_args__ = (
        UniqueConstraint("shelf_id", "product_id", name="uq_shelf_product_map"),
        Index("ix_shelf_product_map_shelf_product", "shelf_id", "product_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenants.id", ondelete="CASCADE"), index=True)
    store_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("stores.id", ondelete="CASCADE"), index=True)
    shelf_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("shelves.id", ondelete="CASCADE"), index=True)
    product_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("products.id", ondelete="CASCADE"), index=True)
    position: Mapped[int] = mapped_column(Integer, default=0)
    is_primary: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, server_default=func.now())

    shelf: Mapped[Shelf] = relationship(back_populates="product_links")
    product: Mapped["Product"] = relationship()  # noqa: F821 - resolved via catalog model


class Inventory(Base):
    __tablename__ = "inventory"
    __table_args__ = (
        UniqueConstraint("store_id", "product_id", name="uq_inventory_store_product"),
        CheckConstraint("quantity >= 0", name="ck_inventory_quantity_nonneg"),
        CheckConstraint("reserved_quantity >= 0", name="ck_inventory_reserved_nonneg"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenants.id", ondelete="CASCADE"), index=True)
    store_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("stores.id", ondelete="CASCADE"), index=True)
    product_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("products.id", ondelete="CASCADE"), index=True)
    quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3), default=Decimal(0))
    reserved_quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3), default=Decimal(0))
    version: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow, onupdate=_utcnow, server_default=func.now()
    )

    product: Mapped["Product"] = relationship()  # noqa: F821


class StockMovement(Base):
    __tablename__ = "stock_movements"
    __table_args__ = (
        Index("ix_stock_movements_store_created", "store_id", "created_at"),
        Index("ix_stock_movements_store_product", "store_id", "product_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenants.id", ondelete="CASCADE"), index=True)
    store_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("stores.id", ondelete="CASCADE"), index=True)
    product_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("products.id", ondelete="CASCADE"), index=True)
    quantity_delta: Mapped[Decimal] = mapped_column(Numeric(12, 3))
    resulting_quantity: Mapped[Decimal | None] = mapped_column(Numeric(12, 3))
    movement_type: Mapped[str] = mapped_column(String(30), index=True)
    reference_type: Mapped[str | None] = mapped_column(String(30))
    reference_id: Mapped[str | None] = mapped_column(String(64))
    notes: Mapped[str | None] = mapped_column(Text)
    created_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, server_default=func.now())

    product: Mapped["Product"] = relationship()  # noqa: F821


class ExpiryBatch(Base):
    __tablename__ = "expiry_batches"
    __table_args__ = (
        Index("ix_expiry_batches_store_expiry", "store_id", "expiry_date"),
        Index("ix_expiry_batches_store_product", "store_id", "product_id"),
        CheckConstraint("quantity >= 0", name="ck_expiry_batches_quantity_nonneg"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenants.id", ondelete="CASCADE"), index=True)
    store_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("stores.id", ondelete="CASCADE"), index=True)
    product_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("products.id", ondelete="CASCADE"), index=True)
    batch_code: Mapped[str | None] = mapped_column(String(64))
    quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3), default=Decimal(0))
    expiry_date: Mapped[date] = mapped_column(Date)
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, server_default=func.now())
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow, onupdate=_utcnow, server_default=func.now()
    )

    product: Mapped["Product"] = relationship()  # noqa: F821
