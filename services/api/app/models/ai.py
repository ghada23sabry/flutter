import uuid
from datetime import UTC, datetime
from decimal import Decimal

from sqlalchemy import (
    CheckConstraint,
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
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.db import Base

# Scan lifecycle: a session is created (processing), the scan runs, and the
# session settles into completed / needs_review / failed. Confirmation and
# cancellation are later steps (M4-A.4). A scan NEVER auto-applies a stock
# change — inventory mutation happens only on explicit confirmation.
SCAN_STATUSES = {"processing", "needs_review", "confirmed", "cancelled", "completed", "failed"}

# Business operation a scan session runs. `count` replaces shelf quantities
# (COUNT movements); `receive` adds detected quantities (PURCHASE movements);
# `sale` subtracts them (SALE movements). Only vocabulary already present in
# the movement enum is used — no new movement types.
SCAN_OPERATIONS = {"count", "receive", "sale"}

DETECTION_METHODS = {"barcode", "visual", "ocr", "manual"}
DETECTION_STATUSES = {"accepted", "needs_review"}

RECONCILIATION_STATUSES = {"no_change", "needs_review", "applied"}
RECONCILIATION_RESOLUTIONS = {"apply", "ignore"}


def _utcnow() -> datetime:
    return datetime.now(UTC)


class ScanSession(Base):
    __tablename__ = "scan_sessions"
    __table_args__ = (
        Index("ix_scan_sessions_store_created", "store_id", "created_at"),
        Index("ix_scan_sessions_store_status", "store_id", "status"),
        CheckConstraint("image_count >= 0", name="ck_scan_sessions_image_count_nonneg"),
        CheckConstraint("operation IN ('count', 'receive', 'sale')", name="ck_scan_sessions_operation"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenants.id", ondelete="CASCADE"), index=True)
    store_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("stores.id", ondelete="CASCADE"), index=True)
    shelf_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("shelves.id", ondelete="SET NULL"), index=True)
    status: Mapped[str] = mapped_column(String(20), default="processing")
    operation: Mapped[str] = mapped_column(String(10), default="count")
    note: Mapped[str | None] = mapped_column(Text)
    image_count: Mapped[int] = mapped_column(Integer, default=0)
    started_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    completed_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow, onupdate=_utcnow, server_default=func.now()
    )
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    detections: Mapped[list["ScanDetection"]] = relationship(
        back_populates="session", cascade="all, delete-orphan"
    )
    reconciliations: Mapped[list["ScanReconciliation"]] = relationship(
        back_populates="session", cascade="all, delete-orphan"
    )


class ScanDetection(Base):
    __tablename__ = "scan_detections"
    __table_args__ = (
        Index("ix_scan_detections_store_product", "store_id", "product_id"),
        CheckConstraint("quantity_detected > 0", name="ck_scan_detections_quantity_positive"),
        CheckConstraint(
            "confidence IS NULL OR (confidence >= 0 AND confidence <= 1)",
            name="ck_scan_detections_confidence_range",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenants.id", ondelete="CASCADE"), index=True)
    store_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("stores.id", ondelete="CASCADE"), index=True)
    session_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("scan_sessions.id", ondelete="CASCADE"), index=True
    )
    image_key: Mapped[str | None] = mapped_column(String(255))
    method: Mapped[str] = mapped_column(String(30))
    detected_sku: Mapped[str | None] = mapped_column(String(64))
    detected_barcode: Mapped[str | None] = mapped_column(String(64))
    product_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("products.id", ondelete="SET NULL"), index=True
    )
    confidence: Mapped[Decimal | None] = mapped_column(Numeric(5, 4))
    quantity_detected: Mapped[Decimal] = mapped_column(Numeric(12, 3))
    status: Mapped[str] = mapped_column(String(20), default="accepted")
    meta: Mapped[dict | None] = mapped_column(JSONB)
    created_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, server_default=func.now())

    session: Mapped[ScanSession] = relationship(back_populates="detections")


class ScanReconciliation(Base):
    __tablename__ = "scan_reconciliations"
    __table_args__ = (
        UniqueConstraint("session_id", "product_id", name="uq_scan_reconciliations_session_product"),
        Index("ix_scan_reconciliations_store_product", "store_id", "product_id"),
        CheckConstraint("detected_quantity >= 0", name="ck_scan_reconciliations_detected_nonneg"),
        CheckConstraint("system_quantity >= 0", name="ck_scan_reconciliations_system_nonneg"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenants.id", ondelete="CASCADE"), index=True)
    store_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("stores.id", ondelete="CASCADE"), index=True)
    session_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("scan_sessions.id", ondelete="CASCADE"), index=True
    )
    product_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("products.id", ondelete="CASCADE"), index=True
    )
    detected_quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3))
    system_quantity: Mapped[Decimal] = mapped_column(Numeric(12, 3))
    variance: Mapped[Decimal] = mapped_column(Numeric(12, 3))
    status: Mapped[str] = mapped_column(String(20), default="needs_review")
    resolution: Mapped[str | None] = mapped_column(String(20))
    confirmed_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    confirmed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow, onupdate=_utcnow, server_default=func.now()
    )

    session: Mapped[ScanSession] = relationship(back_populates="reconciliations")
    product: Mapped["Product"] = relationship()  # noqa: F821 - resolved via catalog model
