import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy import func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.audit import write_audit
from app.core.db import get_db
from app.core.errors import CODE_CONFLICT, CODE_NOT_FOUND, AppError
from app.core.security import AuthContext, require_permission
from app.models import Product, Supplier, SupplierProduct
from app.schemas import (
    ActionResponse,
    Page,
    SupplierIn,
    SupplierOut,
    SupplierProductIn,
    SupplierProductOut,
    SupplierProductUpdate,
    SupplierUpdate,
)
from app.services.catalog_service import clean_required, get_scoped_product, get_scoped_supplier

router = APIRouter(prefix="/suppliers", tags=["catalog"])

PERMISSION_VIEW = "suppliers.view"
PERMISSION_MANAGE = "suppliers.manage"


@router.get("", response_model=Page[SupplierOut])
async def list_suppliers(
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    q: Annotated[str | None, Query(max_length=120)] = None,
    status: Annotated[str | None, Query(pattern="^(active|inactive)$")] = None,
    page: Annotated[int, Query(ge=1)] = 1,
    page_size: Annotated[int, Query(ge=1, le=100)] = 20,
):
    query = select(Supplier).where(Supplier.tenant_id == ctx.tenant.id)
    if q:
        term = f"%{q.strip().lower()}%"
        query = query.where(
            or_(
                func.lower(Supplier.name).like(term),
                func.lower(func.coalesce(Supplier.contact_name, "")).like(term),
                func.lower(func.coalesce(Supplier.phone, "")).like(term),
                func.lower(func.coalesce(Supplier.email, "")).like(term),
            )
        )
    if status:
        query = query.where(Supplier.status == status)
    total = (
        await db.execute(select(func.count()).select_from(query.subquery()))
    ).scalar_one()
    suppliers = (
        await db.execute(
            query.order_by(Supplier.name.asc()).offset((page - 1) * page_size).limit(page_size)
        )
    ).scalars().all()
    pages = (total + page_size - 1) // page_size if total else 0
    return Page[SupplierOut](
        items=[SupplierOut.model_validate(s) for s in suppliers],
        total=total,
        page=page,
        page_size=page_size,
        pages=pages,
    )


@router.post("", response_model=SupplierOut, status_code=201)
async def create_supplier(
    body: SupplierIn,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_MANAGE))],
    db: Annotated[AsyncSession, Depends(get_db)],
):
    supplier = Supplier(
        tenant_id=ctx.tenant.id,
        name=clean_required(body.name, "name"),
        contact_name=body.contact_name.strip() if body.contact_name else None,
        phone=body.phone.strip() if body.phone else None,
        email=body.email.strip() if body.email else None,
        address=body.address.strip() if body.address else None,
        notes=body.notes.strip() if body.notes else None,
    )
    db.add(supplier)
    await db.flush()
    await write_audit(
        db,
        action="supplier_created",
        entity_type="supplier",
        entity_id=str(supplier.id),
        tenant_id=ctx.tenant.id,
        store_id=None,
        user_id=ctx.user.id,
        after={"name": supplier.name},
    )
    await db.commit()
    await db.refresh(supplier)
    return SupplierOut.model_validate(supplier)


@router.get("/{supplier_id}", response_model=SupplierOut)
async def get_supplier(
    supplier_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
):
    supplier = await get_scoped_supplier(db, ctx, supplier_id)
    return SupplierOut.model_validate(supplier)


@router.patch("/{supplier_id}", response_model=SupplierOut)
async def update_supplier(
    supplier_id: uuid.UUID,
    body: SupplierUpdate,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_MANAGE))],
    db: Annotated[AsyncSession, Depends(get_db)],
):
    supplier = await get_scoped_supplier(db, ctx, supplier_id)
    before = {"name": supplier.name, "status": supplier.status}
    updates = body.model_dump(exclude_unset=True)
    for field in ("contact_name", "phone", "email", "address", "notes"):
        if field in updates:
            value = updates[field]
            setattr(supplier, field, value.strip() if value else None)
    if "name" in updates and updates["name"] is not None:
        supplier.name = clean_required(updates["name"], "name")
    if "status" in updates and updates["status"] is not None:
        supplier.status = updates["status"]
    await db.flush()
    await write_audit(
        db,
        action="supplier_updated",
        entity_type="supplier",
        entity_id=str(supplier.id),
        tenant_id=ctx.tenant.id,
        store_id=None,
        user_id=ctx.user.id,
        before=before,
        after={"name": supplier.name, "status": supplier.status},
    )
    await db.commit()
    await db.refresh(supplier)
    return SupplierOut.model_validate(supplier)


@router.get("/{supplier_id}/products", response_model=list[SupplierProductOut])
async def list_supplier_products(
    supplier_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
):
    await get_scoped_supplier(db, ctx, supplier_id)
    rows = (
        await db.execute(
            select(SupplierProduct, Product.name, Product.sku)
            .join(Product, SupplierProduct.product_id == Product.id)
            .where(
                SupplierProduct.tenant_id == ctx.tenant.id,
                SupplierProduct.supplier_id == supplier_id,
            )
            .order_by(SupplierProduct.is_preferred.desc(), Product.name.asc())
        )
    ).all()
    items = []
    for link, product_name, product_sku in rows:
        out = SupplierProductOut.model_validate(link)
        items.append(out.model_copy(update={"product_name": product_name, "product_sku": product_sku}))
    return items


@router.post("/{supplier_id}/products", response_model=SupplierProductOut, status_code=201)
async def link_product(
    supplier_id: uuid.UUID,
    body: SupplierProductIn,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_MANAGE))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    supplier = await get_scoped_supplier(db, ctx, supplier_id)
    product = await get_scoped_product(db, ctx, store_id, body.product_id)
    link = SupplierProduct(
        tenant_id=ctx.tenant.id,
        supplier_id=supplier.id,
        product_id=product.id,
        supplier_sku=body.supplier_sku.strip() if body.supplier_sku else None,
        supplier_cost=body.supplier_cost,
        lead_time_days=body.lead_time_days,
        is_preferred=body.is_preferred,
    )
    db.add(link)
    try:
        await db.flush()
    except IntegrityError as exc:
        await db.rollback()
        raise AppError(CODE_CONFLICT, "This supplier is already linked to the product", 409) from exc
    await write_audit(
        db,
        action="supplier_product_linked",
        entity_type="supplier_product",
        entity_id=str(link.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        after={"supplier_id": str(supplier.id), "product_id": str(product.id)},
    )
    await db.commit()
    await db.refresh(link)
    out = SupplierProductOut.model_validate(link)
    return out.model_copy(update={"product_name": product.name, "product_sku": product.sku})


@router.patch("/{supplier_id}/products/{product_id}", response_model=SupplierProductOut)
async def update_link(
    supplier_id: uuid.UUID,
    product_id: uuid.UUID,
    body: SupplierProductUpdate,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_MANAGE))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    await get_scoped_supplier(db, ctx, supplier_id)
    product = await get_scoped_product(db, ctx, store_id, product_id)
    link = (
        await db.execute(
            select(SupplierProduct).where(
                SupplierProduct.tenant_id == ctx.tenant.id,
                SupplierProduct.supplier_id == supplier_id,
                SupplierProduct.product_id == product.id,
            )
        )
    ).scalar_one_or_none()
    if link is None:
        raise AppError(CODE_NOT_FOUND, "Supplier-product link not found", 404)
    updates = body.model_dump(exclude_unset=True)
    if "supplier_sku" in updates:
        link.supplier_sku = updates["supplier_sku"].strip() if updates["supplier_sku"] else None
    if "supplier_cost" in updates:
        link.supplier_cost = updates["supplier_cost"]
    if "lead_time_days" in updates:
        link.lead_time_days = updates["lead_time_days"]
    if "is_preferred" in updates and updates["is_preferred"] is not None:
        link.is_preferred = updates["is_preferred"]
    await db.flush()
    await write_audit(
        db,
        action="supplier_product_updated",
        entity_type="supplier_product",
        entity_id=str(link.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
    )
    await db.commit()
    await db.refresh(link)
    out = SupplierProductOut.model_validate(link)
    return out.model_copy(update={"product_name": product.name, "product_sku": product.sku})


@router.delete("/{supplier_id}/products/{product_id}", response_model=ActionResponse)
async def unlink_product(
    supplier_id: uuid.UUID,
    product_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_MANAGE))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    await get_scoped_supplier(db, ctx, supplier_id)
    await get_scoped_product(db, ctx, store_id, product_id)
    link = (
        await db.execute(
            select(SupplierProduct).where(
                SupplierProduct.tenant_id == ctx.tenant.id,
                SupplierProduct.supplier_id == supplier_id,
                SupplierProduct.product_id == product_id,
            )
        )
    ).scalar_one_or_none()
    if link is None:
        raise AppError(CODE_NOT_FOUND, "Supplier-product link not found", 404)
    await db.delete(link)
    await write_audit(
        db,
        action="supplier_product_unlinked",
        entity_type="supplier_product",
        entity_id=str(link.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        before={"supplier_id": str(supplier_id), "product_id": str(product_id)},
    )
    await db.commit()
    return ActionResponse()
