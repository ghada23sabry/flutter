import logging
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy import func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.audit import write_audit
from app.core.barcode_enrichment import enrich_barcode_off
from app.core.db import get_db
from app.core.errors import CODE_CONFLICT, CODE_NOT_FOUND, AppError
from app.core.security import AuthContext, require_permission
from app.models import Category, Product, Supplier, SupplierProduct
from app.schemas import (
    BarcodeEnrichment,
    Page,
    ProductIn,
    ProductOut,
    ProductUpdate,
    SupplierProductOut,
)
from app.services.catalog_service import (
    clean_required,
    get_scoped_category,
    get_scoped_product,
    normalize_barcode,
    require_store,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/products", tags=["catalog"])

PERMISSION_VIEW = "products.view"
PERMISSION_MANAGE = "products.manage"


def _product_out(product: Product, category_name: str | None = None) -> ProductOut:
    return ProductOut.model_validate(product).model_copy(update={"category_name": category_name})


async def _category_name(db: AsyncSession, category_id: uuid.UUID | None) -> str | None:
    if category_id is None:
        return None
    row = (await db.execute(select(Category.name).where(Category.id == category_id))).scalar_one_or_none()
    return row


async def _apply_search(query, q: str | None):
    if not q:
        return query
    term = q.strip().lower()
    pattern = f"%{term}%"
    barcode = normalize_barcode(q)
    conditions = [
        func.lower(Product.name).like(pattern),
        func.lower(Product.sku).like(pattern),
    ]
    if barcode:
        conditions.append(Product.barcode.like(f"%{barcode}%"))
    return query.where(or_(*conditions))


async def _list_page(db: AsyncSession, query, page: int, page_size: int):
    total = (
        await db.execute(select(func.count()).select_from(query.subquery()))
    ).scalar_one()
    rows = (await db.execute(query.offset((page - 1) * page_size).limit(page_size))).all()
    items = [_product_out(p, c) for p, c in rows]
    pages = (total + page_size - 1) // page_size if total else 0
    return Page[ProductOut](items=items, total=total, page=page, page_size=page_size, pages=pages)


@router.get("", response_model=Page[ProductOut])
async def list_products(
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
    q: Annotated[str | None, Query(max_length=120)] = None,
    category_id: Annotated[uuid.UUID | None, Query()] = None,
    status: Annotated[str | None, Query(pattern="^(active|inactive)$")] = None,
    page: Annotated[int, Query(ge=1)] = 1,
    page_size: Annotated[int, Query(ge=1, le=100)] = 20,
):
    require_store(ctx, store_id)
    query = (
        select(Product, Category.name)
        .outerjoin(Category, Product.category_id == Category.id)
        .where(
            Product.tenant_id == ctx.tenant.id,
            Product.store_id == store_id,
        )
    )
    query = await _apply_search(query, q)
    if category_id:
        query = query.where(Product.category_id == category_id)
    if status:
        query = query.where(Product.status == status)
    query = query.order_by(Product.created_at.desc())
    return await _list_page(db, query, page, page_size)


@router.post("", response_model=ProductOut, status_code=201)
async def create_product(
    body: ProductIn,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_MANAGE))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    if body.category_id is not None:
        await get_scoped_category(db, ctx, store_id, body.category_id)
    product = Product(
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        category_id=body.category_id,
        name=clean_required(body.name, "name"),
        brand=body.brand.strip() if body.brand else None,
        sku=clean_required(body.sku, "sku"),
        barcode=normalize_barcode(body.barcode),
        description=body.description.strip() if body.description else None,
        unit=clean_required(body.unit, "unit"),
        cost_price=body.cost_price,
        selling_price=body.selling_price,
        reorder_point=body.reorder_point,
        reorder_quantity=body.reorder_quantity,
        expiry_tracking_enabled=body.expiry_tracking_enabled,
        image_url=body.image_url,
    )
    db.add(product)
    try:
        await db.flush()
    except IntegrityError as exc:
        await db.rollback()
        raise AppError(CODE_CONFLICT, "A product with this SKU or barcode already exists in this store", 409) from exc
    await write_audit(
        db,
        action="product_created",
        entity_type="product",
        entity_id=str(product.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        after={"name": product.name, "sku": product.sku, "barcode": product.barcode, "brand": product.brand},
    )
    await db.commit()
    await db.refresh(product)
    return _product_out(product, await _category_name(db, product.category_id))


@router.get("/lookup/sku/{sku}", response_model=ProductOut)
async def lookup_by_sku(
    sku: str,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    product = (
        await db.execute(
            select(Product).where(
                Product.tenant_id == ctx.tenant.id,
                Product.store_id == store_id,
                Product.sku == sku.strip(),
            )
        )
    ).scalar_one_or_none()
    if product is None:
        raise AppError(CODE_NOT_FOUND, "Product not found", 404)
    return _product_out(product, await _category_name(db, product.category_id))


@router.get("/lookup/barcode/{barcode}", response_model=ProductOut)
async def lookup_by_barcode(
    barcode: str,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    normalized = normalize_barcode(barcode)
    product = (
        await db.execute(
            select(Product).where(
                Product.tenant_id == ctx.tenant.id,
                Product.store_id == store_id,
                Product.barcode == normalized,
            )
        )
    ).scalar_one_or_none()
    if product is None:
        raise AppError(CODE_NOT_FOUND, "Product not found", 404)
    return _product_out(product, await _category_name(db, product.category_id))


# ── Barcode enrichment (must precede /{product_id} catch-all) ──────────────


@router.get("/enrich/barcode/{barcode}", response_model=BarcodeEnrichment)
async def enrich_barcode(
    barcode: str,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    store_id: Annotated[uuid.UUID, Query()],
):
    """Look up product information for an unknown barcode via Open Food Facts.

    Returns whatever public data is available; never returns errors for
    missing products (just empty fields).  The caller decides what to do
    with partial data.
    """
    require_store(ctx, store_id)
    normalized = normalize_barcode(barcode)
    if not normalized:
        raise AppError(CODE_NOT_FOUND, "Invalid barcode", 404)

    off = await enrich_barcode_off(normalized)
    return BarcodeEnrichment(
        barcode=off.barcode,
        name=off.name,
        brand=off.brand,
        category=off.category,
        description=off.description,
    )


@router.get("/{product_id}", response_model=ProductOut)
async def get_product(
    product_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    product = await get_scoped_product(db, ctx, store_id, product_id)
    return _product_out(product, await _category_name(db, product.category_id))


@router.patch("/{product_id}", response_model=ProductOut)
async def update_product(
    product_id: uuid.UUID,
    body: ProductUpdate,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_MANAGE))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    product = await get_scoped_product(db, ctx, store_id, product_id)
    before = {"name": product.name, "sku": product.sku, "barcode": product.barcode, "brand": product.brand, "status": product.status}
    updates = body.model_dump(exclude_unset=True)
    if "category_id" in updates:
        if updates["category_id"] is not None:
            await get_scoped_category(db, ctx, store_id, updates["category_id"])
        product.category_id = updates["category_id"]
    if "name" in updates and updates["name"] is not None:
        product.name = clean_required(updates["name"], "name")
    if "brand" in updates:
        product.brand = updates["brand"].strip() if updates["brand"] else None
    if "sku" in updates and updates["sku"] is not None:
        product.sku = clean_required(updates["sku"], "sku")
    if "barcode" in updates:
        product.barcode = normalize_barcode(updates["barcode"])
    if "description" in updates:
        product.description = updates["description"].strip() if updates["description"] else None
    if "unit" in updates and updates["unit"] is not None:
        product.unit = clean_required(updates["unit"], "unit")
    if "cost_price" in updates:
        product.cost_price = updates["cost_price"]
    if "selling_price" in updates:
        product.selling_price = updates["selling_price"]
    if "reorder_point" in updates:
        product.reorder_point = updates["reorder_point"]
    if "reorder_quantity" in updates:
        product.reorder_quantity = updates["reorder_quantity"]
    if "expiry_tracking_enabled" in updates:
        product.expiry_tracking_enabled = updates["expiry_tracking_enabled"]
    if "image_url" in updates:
        product.image_url = updates["image_url"]
    if "status" in updates and updates["status"] is not None:
        product.status = updates["status"]
    try:
        await db.flush()
    except IntegrityError as exc:
        await db.rollback()
        raise AppError(CODE_CONFLICT, "A product with this SKU or barcode already exists in this store", 409) from exc
    await write_audit(
        db,
        action="product_updated",
        entity_type="product",
        entity_id=str(product.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        before=before,
        after={"name": product.name, "sku": product.sku, "barcode": product.barcode, "brand": product.brand, "status": product.status},
    )
    await db.commit()
    await db.refresh(product)
    return _product_out(product, await _category_name(db, product.category_id))


@router.get("/{product_id}/suppliers", response_model=list[SupplierProductOut])
async def list_product_suppliers(
    product_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    await get_scoped_product(db, ctx, store_id, product_id)
    rows = (
        await db.execute(
            select(SupplierProduct, Supplier.name, Product.sku)
            .join(Supplier, SupplierProduct.supplier_id == Supplier.id)
            .join(Product, SupplierProduct.product_id == Product.id)
            .where(
                SupplierProduct.tenant_id == ctx.tenant.id,
                SupplierProduct.product_id == product_id,
            )
            .order_by(SupplierProduct.is_preferred.desc(), Supplier.name.asc())
        )
    ).all()
    items = []
    for link, supplier_name, product_sku in rows:
        out = SupplierProductOut.model_validate(link)
        items.append(
            out.model_copy(
                update={
                    "supplier_name": supplier_name,
                    "product_sku": product_sku,
                }
            )
        )
    return items
