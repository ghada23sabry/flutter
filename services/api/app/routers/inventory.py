import uuid
from decimal import Decimal
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy import func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.audit import write_audit
from app.core.db import get_db
from app.core.errors import CODE_CONFLICT, CODE_NOT_FOUND, CODE_VALIDATION_ERROR, AppError
from app.core.security import AuthContext, require_permission
from app.models import (
    Category,
    ExpiryBatch,
    Inventory,
    Product,
    Shelf,
    ShelfProductMap,
    StockMovement,
    User,
    Zone,
)
from app.schemas import (
    ActionResponse,
    AdjustmentIn,
    ExpiryBatchIn,
    ExpiryBatchOut,
    ExpiryBatchUpdate,
    ExpiryBatchWriteOffIn,
    InventoryOut,
    InventorySummaryOut,
    MovementType,
    OpeningStockIn,
    Page,
    ProductStockOut,
    ShelfIn,
    ShelfProductMapIn,
    ShelfProductMapOut,
    ShelfUpdate,
    ShelfWithZoneOut,
    StockMovementOut,
    ZoneIn,
    ZoneOut,
    ZoneUpdate,
)
from app.services.catalog_service import (
    clean_required,
    get_scoped_category,
    get_scoped_product,
    normalize_barcode,
    require_store,
)
from app.services.inventory_service import (
    apply_adjustment,
    apply_opening_stock,
    compute_stock_status,
    create_expiry_batch,
    days_remaining,
    expiry_status,
    get_scoped_expiry_batch,
    get_scoped_shelf,
    get_scoped_zone,
    today_utc,
    value_for,
    write_off_expiry_batch,
)

router = APIRouter(prefix="/inventory", tags=["inventory"])

PERMISSION_VIEW = "inventory.view"
PERMISSION_ADJUST = "inventory.adjust"
PERMISSION_LAYOUT = "inventory.manage_layout"
PERMISSION_MOVEMENTS = "inventory.view_movements"
PERMISSION_EXPIRY = "inventory.manage_expiry"


def _zone_out(zone: Zone) -> ZoneOut:
    return ZoneOut.model_validate(zone)


def _shelf_out(shelf: Shelf, zone_name: str | None = None) -> ShelfWithZoneOut:
    return ShelfWithZoneOut.model_validate(shelf).model_copy(update={"zone_name": zone_name})


async def _zone_name(db: AsyncSession, zone_id: uuid.UUID) -> str:
    return (await db.execute(select(Zone.name).where(Zone.id == zone_id))).scalar_one()


def _expiry_out(batch: ExpiryBatch, product: Product | None = None) -> ExpiryBatchOut:
    today = today_utc()
    out = ExpiryBatchOut.model_validate(batch)
    status = expiry_status(batch.expiry_date, today=today)
    return out.model_copy(
        update={
            "status": status,
            "days_remaining": days_remaining(batch.expiry_date, today=today),
            "value": value_for(batch.quantity, product.cost_price) if product else Decimal(0),
            "product_name": product.name if product else None,
            "sku": product.sku if product else None,
            "barcode": product.barcode if product else None,
        }
    )


def _movement_out(
    movement: StockMovement, product_name: str | None = None, sku: str | None = None, created_by_name: str | None = None
) -> StockMovementOut:
    return StockMovementOut.model_validate(movement).model_copy(
        update={"product_name": product_name, "sku": sku, "created_by_name": created_by_name}
    )


async def _nearest_expiry_map(db: AsyncSession, ctx: AuthContext, store_id: uuid.UUID) -> dict[uuid.UUID, dict]:
    rows = (
        await db.execute(
            select(ExpiryBatch.product_id, func.min(ExpiryBatch.expiry_date))
            .where(
                ExpiryBatch.tenant_id == ctx.tenant.id,
                ExpiryBatch.store_id == store_id,
                ExpiryBatch.quantity > 0,
            )
            .group_by(ExpiryBatch.product_id)
        )
    ).all()
    today = today_utc()
    return {
        product_id: {"date": min_date, "status": expiry_status(min_date, today=today)}
        for product_id, min_date in rows
    }


def _inventory_out(
    product: Product, inventory: Inventory | None, category_name: str | None, nearest: dict | None = None
) -> InventoryOut:
    quantity = inventory.quantity if inventory else Decimal(0)
    reserved = inventory.reserved_quantity if inventory else Decimal(0)
    return InventoryOut(
        product_id=product.id,
        product_name=product.name,
        sku=product.sku,
        barcode=product.barcode,
        unit=product.unit,
        category_name=category_name,
        cost_price=product.cost_price,
        reorder_point=product.reorder_point,
        reorder_quantity=product.reorder_quantity,
        expiry_tracking_enabled=product.expiry_tracking_enabled,
        quantity=quantity,
        reserved_quantity=reserved,
        available_quantity=quantity - reserved,
        stock_status=compute_stock_status(quantity, product.reorder_point),
        value=value_for(quantity, product.cost_price),
        nearest_expiry_date=nearest["date"] if nearest else None,
        nearest_expiry_status=nearest["status"] if nearest else None,
        updated_at=inventory.updated_at if inventory else product.created_at,
    )


async def _product_stock_detail(
    db: AsyncSession, ctx: AuthContext, store_id: uuid.UUID, product_id: uuid.UUID
) -> ProductStockOut:
    product = await get_scoped_product(db, ctx, store_id, product_id)
    inventory = (
        await db.execute(
            select(Inventory).where(
                Inventory.tenant_id == ctx.tenant.id,
                Inventory.store_id == store_id,
                Inventory.product_id == product_id,
            )
        )
    ).scalar_one_or_none()
    category_name = (
        await db.execute(select(Category.name).where(Category.id == product.category_id))
    ).scalar_one_or_none() if product.category_id else None

    shelf_rows = (
        await db.execute(
            select(ShelfProductMap, Shelf, Zone)
            .join(Shelf, ShelfProductMap.shelf_id == Shelf.id)
            .join(Zone, Shelf.zone_id == Zone.id)
            .where(
                ShelfProductMap.tenant_id == ctx.tenant.id,
                ShelfProductMap.store_id == store_id,
                ShelfProductMap.product_id == product_id,
            )
            .order_by(Shelf.label.asc())
        )
    ).all()
    shelves = [
        _shelf_out(shelf, zone_name=zone.name) for _, shelf, zone in shelf_rows
    ]

    batches = (
        await db.execute(
            select(ExpiryBatch)
            .where(
                ExpiryBatch.tenant_id == ctx.tenant.id,
                ExpiryBatch.store_id == store_id,
                ExpiryBatch.product_id == product_id,
            )
            .order_by(ExpiryBatch.expiry_date.asc())
        )
    ).scalars().all()
    expiry_batches = [_expiry_out(b, product) for b in batches]

    movements = (
        await db.execute(
            select(StockMovement)
            .where(
                StockMovement.tenant_id == ctx.tenant.id,
                StockMovement.store_id == store_id,
                StockMovement.product_id == product_id,
            )
            .order_by(StockMovement.created_at.desc())
            .limit(20)
        )
    ).scalars().all()
    recent_movements = [_movement_out(m) for m in movements]

    quantity = inventory.quantity if inventory else Decimal(0)
    reserved = inventory.reserved_quantity if inventory else Decimal(0)
    return ProductStockOut(
        product_id=product.id,
        product_name=product.name,
        sku=product.sku,
        barcode=product.barcode,
        unit=product.unit,
        category_id=product.category_id,
        category_name=category_name,
        cost_price=product.cost_price,
        selling_price=product.selling_price,
        reorder_point=product.reorder_point,
        reorder_quantity=product.reorder_quantity,
        expiry_tracking_enabled=product.expiry_tracking_enabled,
        quantity=quantity,
        reserved_quantity=reserved,
        available_quantity=quantity - reserved,
        stock_status=compute_stock_status(quantity, product.reorder_point),
        value=value_for(quantity, product.cost_price),
        has_opening=inventory is not None,
        shelves=shelves,
        expiry_batches=expiry_batches,
        recent_movements=recent_movements,
    )


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


# ── Zones ──────────────────────────────────────────────────────────────────


@router.get("/zones", response_model=list[ZoneOut])
async def list_zones(
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
    status: Annotated[str | None, Query(pattern="^(active|inactive)$")] = None,
):
    require_store(ctx, store_id)
    query = select(Zone).where(Zone.tenant_id == ctx.tenant.id, Zone.store_id == store_id)
    if status:
        query = query.where(Zone.status == status)
    zones = (await db.execute(query.order_by(Zone.name.asc()))).scalars().all()
    return [_zone_out(z) for z in zones]


@router.post("/zones", response_model=ZoneOut, status_code=201)
async def create_zone(
    body: ZoneIn,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_LAYOUT))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    zone = Zone(
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        name=clean_required(body.name, "name"),
        code=body.code.strip().upper() if body.code else None,
    )
    db.add(zone)
    try:
        await db.flush()
    except IntegrityError as exc:
        await db.rollback()
        raise AppError(CODE_CONFLICT, "A zone with this code already exists in this store", 409) from exc
    await write_audit(
        db,
        action="zone_created",
        entity_type="zone",
        entity_id=str(zone.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        after={"name": zone.name, "code": zone.code},
    )
    await db.commit()
    await db.refresh(zone)
    return _zone_out(zone)


@router.get("/zones/{zone_id}", response_model=ZoneOut)
async def get_zone(
    zone_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    return _zone_out(await get_scoped_zone(db, ctx, store_id, zone_id))


@router.patch("/zones/{zone_id}", response_model=ZoneOut)
async def update_zone(
    zone_id: uuid.UUID,
    body: ZoneUpdate,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_LAYOUT))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    zone = await get_scoped_zone(db, ctx, store_id, zone_id)
    before = {"name": zone.name, "status": zone.status}
    updates = body.model_dump(exclude_unset=True)
    if "name" in updates and updates["name"] is not None:
        zone.name = clean_required(updates["name"], "name")
    if "code" in updates:
        zone.code = updates["code"].strip().upper() if updates["code"] else None
    if "status" in updates and updates["status"] is not None:
        zone.status = updates["status"]
    try:
        await db.flush()
    except IntegrityError as exc:
        await db.rollback()
        raise AppError(CODE_CONFLICT, "A zone with this code already exists in this store", 409) from exc
    await write_audit(
        db,
        action="zone_updated",
        entity_type="zone",
        entity_id=str(zone.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        before=before,
        after={"name": zone.name, "status": zone.status},
    )
    await db.commit()
    await db.refresh(zone)
    return _zone_out(zone)


# ── Shelves ────────────────────────────────────────────────────────────────


@router.get("/shelves", response_model=list[ShelfWithZoneOut])
async def list_shelves(
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
    zone_id: Annotated[uuid.UUID | None, Query()] = None,
    status: Annotated[str | None, Query(pattern="^(active|inactive)$")] = None,
):
    require_store(ctx, store_id)
    query = (
        select(Shelf, Zone.name)
        .join(Zone, Shelf.zone_id == Zone.id)
        .where(Shelf.tenant_id == ctx.tenant.id, Shelf.store_id == store_id)
    )
    if zone_id:
        query = query.where(Shelf.zone_id == zone_id)
    if status:
        query = query.where(Shelf.status == status)
    rows = (await db.execute(query.order_by(Zone.name.asc(), Shelf.position.asc()))).all()
    return [_shelf_out(shelf, zone_name) for shelf, zone_name in rows]


@router.post("/shelves", response_model=ShelfWithZoneOut, status_code=201)
async def create_shelf(
    body: ShelfIn,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_LAYOUT))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    await get_scoped_zone(db, ctx, store_id, body.zone_id)
    shelf = Shelf(
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        zone_id=body.zone_id,
        label=clean_required(body.label, "label"),
        code=body.code.strip().upper() if body.code else None,
        position=body.position,
    )
    db.add(shelf)
    try:
        await db.flush()
    except IntegrityError as exc:
        await db.rollback()
        raise AppError(CODE_CONFLICT, "A shelf with this code already exists in this store", 409) from exc
    await write_audit(
        db,
        action="shelf_created",
        entity_type="shelf",
        entity_id=str(shelf.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        after={"label": shelf.label, "code": shelf.code, "zone_id": str(shelf.zone_id)},
    )
    await db.commit()
    await db.refresh(shelf)
    return _shelf_out(shelf, await _zone_name(db, shelf.zone_id))


@router.get("/shelves/{shelf_id}", response_model=ShelfWithZoneOut)
async def get_shelf(
    shelf_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    shelf = await get_scoped_shelf(db, ctx, store_id, shelf_id)
    return _shelf_out(shelf, await _zone_name(db, shelf.zone_id))


@router.patch("/shelves/{shelf_id}", response_model=ShelfWithZoneOut)
async def update_shelf(
    shelf_id: uuid.UUID,
    body: ShelfUpdate,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_LAYOUT))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    shelf = await get_scoped_shelf(db, ctx, store_id, shelf_id)
    before = {"label": shelf.label, "status": shelf.status, "zone_id": str(shelf.zone_id)}
    updates = body.model_dump(exclude_unset=True)
    if "zone_id" in updates and updates["zone_id"] is not None:
        await get_scoped_zone(db, ctx, store_id, updates["zone_id"])
        shelf.zone_id = updates["zone_id"]
    if "label" in updates and updates["label"] is not None:
        shelf.label = clean_required(updates["label"], "label")
    if "code" in updates:
        shelf.code = updates["code"].strip().upper() if updates["code"] else None
    if "position" in updates:
        shelf.position = updates["position"]
    if "status" in updates and updates["status"] is not None:
        shelf.status = updates["status"]
    try:
        await db.flush()
    except IntegrityError as exc:
        await db.rollback()
        raise AppError(CODE_CONFLICT, "A shelf with this code already exists in this store", 409) from exc
    await write_audit(
        db,
        action="shelf_updated",
        entity_type="shelf",
        entity_id=str(shelf.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        before=before,
        after={"label": shelf.label, "status": shelf.status, "zone_id": str(shelf.zone_id)},
    )
    await db.commit()
    await db.refresh(shelf)
    return _shelf_out(shelf, await _zone_name(db, shelf.zone_id))


@router.get("/shelves/{shelf_id}/products", response_model=list[ShelfProductMapOut])
async def list_shelf_products(
    shelf_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    await get_scoped_shelf(db, ctx, store_id, shelf_id)
    rows = (
        await db.execute(
            select(ShelfProductMap, Product)
            .join(Product, ShelfProductMap.product_id == Product.id)
            .where(
                ShelfProductMap.tenant_id == ctx.tenant.id,
                ShelfProductMap.store_id == store_id,
                ShelfProductMap.shelf_id == shelf_id,
            )
            .order_by(ShelfProductMap.position.asc())
        )
    ).all()
    return [
        ShelfProductMapOut.model_validate(m).model_copy(
            update={"product_name": p.name, "sku": p.sku, "barcode": p.barcode}
        )
        for m, p in rows
    ]


@router.post("/shelves/{shelf_id}/products", response_model=ShelfProductMapOut, status_code=201)
async def map_product_to_shelf(
    shelf_id: uuid.UUID,
    body: ShelfProductMapIn,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_LAYOUT))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    await get_scoped_shelf(db, ctx, store_id, shelf_id)
    product = await get_scoped_product(db, ctx, store_id, body.product_id)
    link = ShelfProductMap(
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        shelf_id=shelf_id,
        product_id=body.product_id,
        position=body.position,
        is_primary=body.is_primary,
    )
    db.add(link)
    try:
        await db.flush()
    except IntegrityError as exc:
        await db.rollback()
        raise AppError(CODE_CONFLICT, "This product is already mapped to this shelf", 409) from exc
    await write_audit(
        db,
        action="shelf_product_mapped",
        entity_type="shelf_product_map",
        entity_id=str(link.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        after={"shelf_id": str(shelf_id), "product_id": str(body.product_id)},
    )
    await db.commit()
    await db.refresh(link)
    return ShelfProductMapOut.model_validate(link).model_copy(
        update={"product_name": product.name, "sku": product.sku, "barcode": product.barcode}
    )


@router.delete("/shelves/{shelf_id}/products/{product_id}", response_model=ActionResponse)
async def unmap_product_from_shelf(
    shelf_id: uuid.UUID,
    product_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_LAYOUT))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    await get_scoped_shelf(db, ctx, store_id, shelf_id)
    link = (
        await db.execute(
            select(ShelfProductMap).where(
                ShelfProductMap.tenant_id == ctx.tenant.id,
                ShelfProductMap.store_id == store_id,
                ShelfProductMap.shelf_id == shelf_id,
                ShelfProductMap.product_id == product_id,
            )
        )
    ).scalar_one_or_none()
    if link is None:
        raise AppError(CODE_NOT_FOUND, "Product is not mapped to this shelf", 404)
    await db.delete(link)
    await write_audit(
        db,
        action="shelf_product_unmapped",
        entity_type="shelf_product_map",
        entity_id=str(link.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        after={"shelf_id": str(shelf_id), "product_id": str(product_id)},
    )
    await db.commit()
    return ActionResponse(status="ok")


# ── Stock ──────────────────────────────────────────────────────────────────


@router.get("/stock", response_model=Page[InventoryOut])
async def list_stock(
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
    q: Annotated[str | None, Query(max_length=120)] = None,
    category_id: Annotated[uuid.UUID | None, Query()] = None,
    stock_status: Annotated[str | None, Query(pattern="^(healthy|low_stock|out_of_stock)$")] = None,
    product_status: Annotated[str | None, Query(pattern="^(active|inactive)$")] = None,
    page: Annotated[int, Query(ge=1)] = 1,
    page_size: Annotated[int, Query(ge=1, le=100)] = 20,
):
    require_store(ctx, store_id)
    query = (
        select(Product, Inventory, Category.name)
        .outerjoin(Inventory, (Inventory.product_id == Product.id) & (Inventory.store_id == store_id))
        .outerjoin(Category, Product.category_id == Category.id)
        .where(Product.tenant_id == ctx.tenant.id, Product.store_id == store_id)
    )
    query = await _apply_search(query, q)
    if category_id:
        await get_scoped_category(db, ctx, store_id, category_id)
        query = query.where(Product.category_id == category_id)
    if product_status:
        query = query.where(Product.status == product_status)
    query = query.order_by(Product.name.asc())

    rows = (await db.execute(query)).all()
    nearest_map = await _nearest_expiry_map(db, ctx, store_id)
    items = [_inventory_out(p, inv, category_name, nearest_map.get(p.id)) for p, inv, category_name in rows]
    if stock_status:
        items = [it for it in items if it.stock_status == stock_status]
    total = len(items)
    pages = (total + page_size - 1) // page_size if total else 0
    start = (page - 1) * page_size
    return Page[InventoryOut](items=items[start : start + page_size], total=total, page=page, page_size=page_size, pages=pages)


@router.get("/stock/summary", response_model=InventorySummaryOut)
async def stock_summary(
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    rows = (
        await db.execute(
            select(Product, Inventory)
            .outerjoin(Inventory, (Inventory.product_id == Product.id) & (Inventory.store_id == store_id))
            .where(Product.tenant_id == ctx.tenant.id, Product.store_id == store_id, Product.status == "active")
        )
    ).all()

    batches = (
        await db.execute(
            select(ExpiryBatch.product_id, ExpiryBatch.expiry_date)
            .where(ExpiryBatch.tenant_id == ctx.tenant.id, ExpiryBatch.store_id == store_id, ExpiryBatch.quantity > 0)
        )
    ).all()
    today = today_utc()
    product_expiry: dict[uuid.UUID, str] = {}
    for product_id, expiry_date in batches:
        status = expiry_status(expiry_date, today=today)
        if product_id in product_expiry:
            priority = {"normal": 0, "near_expiry": 1, "expired": 2}
            if priority[status] > priority[product_expiry[product_id]]:
                product_expiry[product_id] = status
        else:
            product_expiry[product_id] = status

    total_value = Decimal(0)
    healthy = low_stock = out_of_stock = 0
    for product, inventory in rows:
        quantity = inventory.quantity if inventory else Decimal(0)
        total_value += value_for(quantity, product.cost_price)
        status = compute_stock_status(quantity, product.reorder_point)
        if status == "healthy":
            healthy += 1
        elif status == "low_stock":
            low_stock += 1
        else:
            out_of_stock += 1

    near_expiry = sum(1 for s in product_expiry.values() if s == "near_expiry")
    expired = sum(1 for s in product_expiry.values() if s == "expired")
    return InventorySummaryOut(
        total_products=len(rows),
        total_value=total_value,
        healthy=healthy,
        low_stock=low_stock,
        out_of_stock=out_of_stock,
        near_expiry=near_expiry,
        expired=expired,
    )


@router.get("/stock/{product_id}", response_model=ProductStockOut)
async def get_stock_detail(
    product_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    return await _product_stock_detail(db, ctx, store_id, product_id)


@router.post("/stock/{product_id}/opening", response_model=ProductStockOut, status_code=201)
async def set_opening_stock(
    product_id: uuid.UUID,
    body: OpeningStockIn,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_ADJUST))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    await apply_opening_stock(
        db,
        ctx,
        store_id=store_id,
        product_id=product_id,
        quantity=body.quantity,
        batch_code=body.batch_code,
        expiry_date=body.expiry_date,
    )
    await db.commit()
    return await _product_stock_detail(db, ctx, store_id, product_id)


@router.patch("/stock/{product_id}", response_model=ProductStockOut)
async def adjust_stock(
    product_id: uuid.UUID,
    body: AdjustmentIn,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_ADJUST))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    await apply_adjustment(
        db,
        ctx,
        store_id=store_id,
        product_id=product_id,
        new_quantity=body.new_quantity,
        delta=body.delta,
        reason=body.reason.strip(),
        expiry_batch_id=body.expiry_batch_id,
        reference_type=body.reference_type,
        reference_id=body.reference_id,
        movement_type=body.movement_type,
    )
    await db.commit()
    return await _product_stock_detail(db, ctx, store_id, product_id)


# ── Expiry batches ─────────────────────────────────────────────────────────


@router.get("/expiry", response_model=list[ExpiryBatchOut])
async def list_expiry_batches(
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
    product_id: Annotated[uuid.UUID | None, Query()] = None,
    status: Annotated[str | None, Query(pattern="^(expired|near_expiry|normal)$")] = None,
):
    require_store(ctx, store_id)
    query = (
        select(ExpiryBatch, Product)
        .join(Product, ExpiryBatch.product_id == Product.id)
        .where(ExpiryBatch.tenant_id == ctx.tenant.id, ExpiryBatch.store_id == store_id)
    )
    if product_id:
        query = query.where(ExpiryBatch.product_id == product_id)
    rows = (await db.execute(query.order_by(ExpiryBatch.expiry_date.asc()))).all()
    items = [_expiry_out(batch, product) for batch, product in rows]
    if status:
        items = [it for it in items if it.status == status]
    return items


@router.post("/expiry", response_model=ExpiryBatchOut, status_code=201)
async def create_batch(
    body: ExpiryBatchIn,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_EXPIRY))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    product = await get_scoped_product(db, ctx, store_id, body.product_id)
    batch = await create_expiry_batch(
        db,
        ctx,
        store_id=store_id,
        product_id=body.product_id,
        quantity=body.quantity,
        expiry_date=body.expiry_date,
        batch_code=body.batch_code,
    )
    await db.commit()
    await db.refresh(batch)
    return _expiry_out(batch, product)


@router.get("/expiry/{batch_id}", response_model=ExpiryBatchOut)
async def get_expiry_batch(
    batch_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    batch = await get_scoped_expiry_batch(db, ctx, store_id, batch_id)
    product = await get_scoped_product(db, ctx, store_id, batch.product_id)
    return _expiry_out(batch, product)


@router.post("/expiry/{batch_id}/write-off", response_model=ExpiryBatchOut)
async def write_off_batch(
    batch_id: uuid.UUID,
    body: ExpiryBatchWriteOffIn,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_EXPIRY))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    batch = await write_off_expiry_batch(
        db,
        ctx,
        store_id=store_id,
        batch_id=batch_id,
        quantity=body.quantity,
        reason=body.reason.strip(),
    )
    await db.commit()
    await db.refresh(batch)
    product = await get_scoped_product(db, ctx, store_id, batch.product_id)
    return _expiry_out(batch, product)


@router.patch("/expiry/{batch_id}", response_model=ExpiryBatchOut)
async def update_expiry_batch(
    batch_id: uuid.UUID,
    body: ExpiryBatchUpdate,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_EXPIRY))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    batch = await get_scoped_expiry_batch(db, ctx, store_id, batch_id)
    before = {"batch_code": batch.batch_code, "expiry_date": batch.expiry_date.isoformat()}
    updates = body.model_dump(exclude_unset=True)
    if "batch_code" in updates:
        batch.batch_code = updates["batch_code"]
    if "expiry_date" in updates and updates["expiry_date"] is not None:
        batch.expiry_date = updates["expiry_date"]
    await write_audit(
        db,
        action="expiry_batch_updated",
        entity_type="expiry_batch",
        entity_id=str(batch.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        before=before,
        after={"batch_code": batch.batch_code, "expiry_date": batch.expiry_date.isoformat()},
    )
    await db.commit()
    await db.refresh(batch)
    product = await get_scoped_product(db, ctx, store_id, batch.product_id)
    return _expiry_out(batch, product)


@router.delete("/expiry/{batch_id}", response_model=ActionResponse)
async def delete_expiry_batch(
    batch_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_EXPIRY))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    batch = await get_scoped_expiry_batch(db, ctx, store_id, batch_id)
    if batch.quantity > 0:
        raise AppError(
            CODE_VALIDATION_ERROR, "Cannot delete a batch with remaining stock; adjust stock first", 422
        )
    await db.delete(batch)
    await write_audit(
        db,
        action="expiry_batch_deleted",
        entity_type="expiry_batch",
        entity_id=str(batch.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        before={"batch_code": batch.batch_code, "expiry_date": batch.expiry_date.isoformat()},
    )
    await db.commit()
    return ActionResponse(status="ok")


# ── Movements ──────────────────────────────────────────────────────────────


@router.get("/movements", response_model=Page[StockMovementOut])
async def list_movements(
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_MOVEMENTS))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
    product_id: Annotated[uuid.UUID | None, Query()] = None,
    movement_type: Annotated[MovementType | None, Query()] = None,
    page: Annotated[int, Query(ge=1)] = 1,
    page_size: Annotated[int, Query(ge=1, le=100)] = 20,
):
    require_store(ctx, store_id)
    query = (
        select(StockMovement, Product.name, Product.sku, User.name)
        .join(Product, StockMovement.product_id == Product.id)
        .outerjoin(User, StockMovement.created_by == User.id)
        .where(StockMovement.tenant_id == ctx.tenant.id, StockMovement.store_id == store_id)
    )
    if product_id:
        query = query.where(StockMovement.product_id == product_id)
    if movement_type:
        query = query.where(StockMovement.movement_type == movement_type)
    total = (await db.execute(select(func.count()).select_from(query.subquery()))).scalar_one()
    rows = (
        await db.execute(
            query.order_by(StockMovement.created_at.desc()).offset((page - 1) * page_size).limit(page_size)
        )
    ).all()
    items = [_movement_out(m, product_name, sku, created_by_name) for m, product_name, sku, created_by_name in rows]
    pages = (total + page_size - 1) // page_size if total else 0
    return Page[StockMovementOut](items=items, total=total, page=page, page_size=page_size, pages=pages)
