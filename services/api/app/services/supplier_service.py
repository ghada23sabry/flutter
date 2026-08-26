"""Supplier creation service for the unknown product flow.

Uses the existing Supplier model — no parallel supplier system.
"""
from __future__ import annotations

import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.audit import write_audit
from app.models.catalog import Supplier, SupplierProduct


async def create_supplier(
    db: AsyncSession,
    *,
    tenant_id: uuid.UUID,
    name: str,
    contact_name: str | None = None,
    phone: str | None = None,
    email: str | None = None,
    address: str | None = None,
    notes: str | None = None,
    actor_id: uuid.UUID | None = None,
) -> Supplier:
    """Create a new supplier within the tenant scope."""
    supplier = Supplier(
        tenant_id=tenant_id,
        name=name.strip(),
        contact_name=contact_name.strip() if contact_name else None,
        phone=phone.strip() if phone else None,
        email=email.strip() if email else None,
        address=address.strip() if address else None,
        notes=notes.strip() if notes else None,
        status="active",
    )
    db.add(supplier)
    await db.flush()
    await write_audit(
        db,
        action="supplier_created",
        entity_type="supplier",
        entity_id=str(supplier.id),
        tenant_id=tenant_id,
        user_id=actor_id,
        after={"name": supplier.name},
    )
    await db.commit()
    await db.refresh(supplier)
    return supplier


async def link_supplier_to_product(
    db: AsyncSession,
    *,
    tenant_id: uuid.UUID,
    store_id: uuid.UUID,
    supplier_id: uuid.UUID,
    product_id: uuid.UUID,
    is_preferred: bool = True,
    actor_id: uuid.UUID | None = None,
) -> SupplierProduct:
    """Link a supplier to a product. Idempotent — returns existing link if present."""
    from sqlalchemy import select

    existing = (
        await db.execute(
            select(SupplierProduct).where(
                SupplierProduct.tenant_id == tenant_id,
                SupplierProduct.supplier_id == supplier_id,
                SupplierProduct.product_id == product_id,
            )
        )
    ).scalar_one_or_none()
    if existing is not None:
        return existing

    link = SupplierProduct(
        tenant_id=tenant_id,
        supplier_id=supplier_id,
        product_id=product_id,
        is_preferred=is_preferred,
    )
    db.add(link)
    await db.flush()
    await db.commit()
    await db.refresh(link)
    return link
