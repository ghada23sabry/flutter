import uuid
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.core.audit import write_audit
from app.core.errors import CODE_CONFLICT, CODE_NOT_FOUND, CODE_VALIDATION_ERROR, AppError
from app.core.security import AuthContext
from app.models import (
    ExpiryBatch,
    Inventory,
    Shelf,
    StockMovement,
    Zone,
)
from app.services.catalog_service import get_scoped_product, require_store


def compute_stock_status(quantity: Decimal, reorder_point: Decimal) -> str:
    """Stock status per M3 §8: out_of_stock → low_stock → healthy."""
    if quantity <= 0:
        return "out_of_stock"
    if reorder_point > 0 and quantity <= reorder_point:
        return "low_stock"
    return "healthy"


def expiry_status(expiry_date: date, *, today: date | None = None, near_expiry_days: int | None = None) -> str:
    """Expiry status against the central near-expiry threshold."""
    today = today or today_utc()
    near = near_expiry_days if near_expiry_days is not None else get_settings().near_expiry_days
    if expiry_date < today:
        return "expired"
    if expiry_date <= today + timedelta(days=near):
        return "near_expiry"
    return "normal"


def days_remaining(expiry_date: date, *, today: date | None = None) -> int:
    today = today or today_utc()
    return (expiry_date - today).days


async def get_scoped_zone(db: AsyncSession, ctx: AuthContext, store_id: uuid.UUID, zone_id: uuid.UUID) -> Zone:
    require_store(ctx, store_id)
    zone = (
        await db.execute(
            select(Zone).where(
                Zone.id == zone_id,
                Zone.tenant_id == ctx.tenant.id,
                Zone.store_id == store_id,
            )
        )
    ).scalar_one_or_none()
    if zone is None:
        raise AppError(CODE_NOT_FOUND, "Zone not found", 404)
    return zone


async def get_scoped_shelf(db: AsyncSession, ctx: AuthContext, store_id: uuid.UUID, shelf_id: uuid.UUID) -> Shelf:
    require_store(ctx, store_id)
    shelf = (
        await db.execute(
            select(Shelf).where(
                Shelf.id == shelf_id,
                Shelf.tenant_id == ctx.tenant.id,
                Shelf.store_id == store_id,
            )
        )
    ).scalar_one_or_none()
    if shelf is None:
        raise AppError(CODE_NOT_FOUND, "Shelf not found", 404)
    return shelf


async def get_scoped_expiry_batch(
    db: AsyncSession, ctx: AuthContext, store_id: uuid.UUID, batch_id: uuid.UUID
) -> ExpiryBatch:
    require_store(ctx, store_id)
    batch = (
        await db.execute(
            select(ExpiryBatch).where(
                ExpiryBatch.id == batch_id,
                ExpiryBatch.tenant_id == ctx.tenant.id,
                ExpiryBatch.store_id == store_id,
            )
        )
    ).scalar_one_or_none()
    if batch is None:
        raise AppError(CODE_NOT_FOUND, "Expiry batch not found", 404)
    return batch


async def apply_opening_stock(
    db: AsyncSession,
    ctx: AuthContext,
    *,
    store_id: uuid.UUID,
    product_id: uuid.UUID,
    quantity: Decimal,
    batch_code: str | None = None,
    expiry_date: date | None = None,
) -> Inventory:
    """Set initial stock (M3 §6). Protected against double application."""
    await get_scoped_product(db, ctx, store_id, product_id)

    existing_opening = (
        await db.execute(
            select(StockMovement.id)
            .where(
                StockMovement.tenant_id == ctx.tenant.id,
                StockMovement.store_id == store_id,
                StockMovement.product_id == product_id,
                StockMovement.movement_type == "OPENING",
            )
            .limit(1)
        )
    ).scalar_one_or_none()
    if existing_opening is not None:
        raise AppError(CODE_CONFLICT, "Opening stock has already been applied for this product", 409)

    inventory = (
        await db.execute(
            select(Inventory)
            .where(Inventory.store_id == store_id, Inventory.product_id == product_id)
            .with_for_update()
        )
    ).scalar_one_or_none()
    if inventory is not None and inventory.quantity != 0:
        raise AppError(CODE_CONFLICT, "This product already has stock in this store", 409)

    if inventory is None:
        inventory = Inventory(
            tenant_id=ctx.tenant.id,
            store_id=store_id,
            product_id=product_id,
            quantity=quantity,
        )
        db.add(inventory)
    else:
        inventory.quantity = quantity
        inventory.version += 1

    db.add(
        StockMovement(
            tenant_id=ctx.tenant.id,
            store_id=store_id,
            product_id=product_id,
            quantity_delta=quantity,
            resulting_quantity=quantity,
            movement_type="OPENING",
            notes="Opening stock",
            created_by=ctx.user.id,
        )
    )

    if expiry_date is not None:
        db.add(
            ExpiryBatch(
                tenant_id=ctx.tenant.id,
                store_id=store_id,
                product_id=product_id,
                batch_code=batch_code,
                quantity=quantity,
                expiry_date=expiry_date,
            )
        )

    await write_audit(
        db,
        action="opening_stock_applied",
        entity_type="product",
        entity_id=str(product_id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        after={"quantity": str(quantity)},
    )

    try:
        await db.flush()
    except IntegrityError as exc:
        await db.rollback()
        raise AppError(CODE_CONFLICT, "Opening stock has already been applied for this product", 409) from exc
    return inventory


async def apply_adjustment(
    db: AsyncSession,
    ctx: AuthContext,
    *,
    store_id: uuid.UUID,
    product_id: uuid.UUID,
    new_quantity: Decimal | None = None,
    delta: Decimal | None = None,
    reason: str,
    expiry_batch_id: uuid.UUID | None = None,
    reference_type: str | None = None,
    reference_id: str | None = None,
    movement_type: str = "ADJUSTMENT",
) -> Inventory:
    """Authorized adjustment (M3 §7). Atomic: lock → validate → update → movement → audit.

    Accepts either an absolute `new_quantity` or a signed `delta` applied to the
    locked current quantity. The delta form is what makes concurrent stock-in /
    stock-out additive under `FOR UPDATE` (no lost updates).
    """
    await get_scoped_product(db, ctx, store_id, product_id)

    inventory = (
        await db.execute(
            select(Inventory)
            .where(Inventory.store_id == store_id, Inventory.product_id == product_id)
            .with_for_update()
        )
    ).scalar_one_or_none()
    if inventory is None:
        raise AppError(CODE_NOT_FOUND, "No stock for this product. Set opening stock first.", 404)

    old_quantity = inventory.quantity

    if delta is not None:
        if delta == 0:
            raise AppError(CODE_VALIDATION_ERROR, "Delta cannot be zero", 422)
        new_quantity = old_quantity + delta
        if new_quantity < 0:
            raise AppError(CODE_VALIDATION_ERROR, "Quantity cannot be negative", 422)
    elif new_quantity is None:
        raise AppError(CODE_VALIDATION_ERROR, "Provide exactly one of new_quantity or delta", 422)

    if new_quantity < 0:
        raise AppError(CODE_VALIDATION_ERROR, "Quantity cannot be negative", 422)
    delta = new_quantity - old_quantity
    if delta == 0:
        raise AppError(CODE_VALIDATION_ERROR, "New quantity is unchanged", 422)

    if expiry_batch_id is not None:
        batch = await get_scoped_expiry_batch(db, ctx, store_id, expiry_batch_id)
        if batch.product_id != product_id:
            raise AppError(CODE_VALIDATION_ERROR, "Expiry batch does not belong to this product", 422)
        if delta > 0:
            raise AppError(
                CODE_VALIDATION_ERROR,
                "Adding stock to an expiry batch is not supported; create a new batch instead",
                422,
            )
        batch.quantity += delta  # delta is negative when stock leaves the batch
        if batch.quantity < 0:
            raise AppError(CODE_VALIDATION_ERROR, "Expiry batch quantity cannot go below zero", 422)

    inventory.quantity = new_quantity
    inventory.version += 1

    db.add(
        StockMovement(
            tenant_id=ctx.tenant.id,
            store_id=store_id,
            product_id=product_id,
            quantity_delta=delta,
            resulting_quantity=new_quantity,
            movement_type=movement_type,
            reference_type=reference_type or ("EXPIRY_BATCH" if expiry_batch_id else None),
            reference_id=str(expiry_batch_id) if expiry_batch_id is not None else reference_id,
            notes=reason,
            created_by=ctx.user.id,
        )
    )

    await write_audit(
        db,
        action="stock_adjusted",
        entity_type="product",
        entity_id=str(product_id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        before={"quantity": str(old_quantity)},
        after={"quantity": str(new_quantity), "delta": str(delta), "reason": reason},
    )
    await db.flush()
    return inventory


async def create_expiry_batch(
    db: AsyncSession,
    ctx: AuthContext,
    *,
    store_id: uuid.UUID,
    product_id: uuid.UUID,
    quantity: Decimal,
    expiry_date: date,
    batch_code: str | None = None,
) -> ExpiryBatch:
    """Register a new expiry batch. Stock arrives with the batch (M3 §9/§11)."""
    await get_scoped_product(db, ctx, store_id, product_id)

    inventory = (
        await db.execute(
            select(Inventory)
            .where(Inventory.store_id == store_id, Inventory.product_id == product_id)
            .with_for_update()
        )
    ).scalar_one_or_none()
    if inventory is None:
        raise AppError(CODE_VALIDATION_ERROR, "Set opening stock before adding expiry batches", 422)

    if quantity < 0:
        raise AppError(CODE_VALIDATION_ERROR, "Quantity cannot be negative", 422)

    old_quantity = inventory.quantity
    inventory.quantity = old_quantity + quantity
    inventory.version += 1

    batch = ExpiryBatch(
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        product_id=product_id,
        batch_code=batch_code,
        quantity=quantity,
        expiry_date=expiry_date,
    )
    db.add(batch)
    await db.flush()

    db.add(
        StockMovement(
            tenant_id=ctx.tenant.id,
            store_id=store_id,
            product_id=product_id,
            quantity_delta=quantity,
            resulting_quantity=inventory.quantity,
            movement_type="ADJUSTMENT",
            reference_type="EXPIRY_BATCH",
            reference_id=str(batch.id),
            notes="New expiry batch received",
            created_by=ctx.user.id,
        )
    )

    await write_audit(
        db,
        action="expiry_batch_created",
        entity_type="expiry_batch",
        entity_id=str(batch.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        after={
            "product_id": str(product_id),
            "quantity": str(quantity),
            "expiry_date": expiry_date.isoformat(),
        },
    )
    await db.flush()
    return batch


async def write_off_expiry_batch(
    db: AsyncSession,
    ctx: AuthContext,
    *,
    store_id: uuid.UUID,
    batch_id: uuid.UUID,
    quantity: Decimal,
    reason: str,
) -> ExpiryBatch:
    """Write off expired stock from a batch (M3 expiry-loss accounting).

    Only batches whose `expiry_date` has passed can be written off. The batch
    and the product inventory are locked with `FOR UPDATE`, then both are
    decremented, a single `WRITE_OFF` ledger row (referencing `EXPIRY_BATCH`)
    is appended, and the mutation is audited — all in one transaction.
    """
    require_store(ctx, store_id)
    if not reason.strip():
        raise AppError(CODE_VALIDATION_ERROR, "Reason is required", 422)
    batch = (
        await db.execute(
            select(ExpiryBatch)
            .where(
                ExpiryBatch.id == batch_id,
                ExpiryBatch.tenant_id == ctx.tenant.id,
                ExpiryBatch.store_id == store_id,
            )
            .with_for_update()
        )
    ).scalar_one_or_none()
    if batch is None:
        raise AppError(CODE_NOT_FOUND, "Expiry batch not found", 404)

    if batch.expiry_date >= today_utc():
        raise AppError(CODE_VALIDATION_ERROR, "Only expired stock can be written off", 422)
    if quantity > batch.quantity:
        raise AppError(CODE_VALIDATION_ERROR, "Cannot write off more than the remaining batch quantity", 422)

    inventory = (
        await db.execute(
            select(Inventory)
            .where(Inventory.store_id == store_id, Inventory.product_id == batch.product_id)
            .with_for_update()
        )
    ).scalar_one_or_none()
    if inventory is None:
        raise AppError(CODE_NOT_FOUND, "No stock for this product. Set opening stock first.", 404)
    if quantity > inventory.quantity:
        raise AppError(CODE_VALIDATION_ERROR, "Not enough stock to write off", 422)

    old_batch_quantity = batch.quantity
    old_inventory_quantity = inventory.quantity
    batch.quantity -= quantity
    inventory.quantity -= quantity
    inventory.version += 1

    db.add(
        StockMovement(
            tenant_id=ctx.tenant.id,
            store_id=store_id,
            product_id=batch.product_id,
            quantity_delta=-quantity,
            resulting_quantity=inventory.quantity,
            movement_type="WRITE_OFF",
            reference_type="EXPIRY_BATCH",
            reference_id=str(batch.id),
            notes=reason,
            created_by=ctx.user.id,
        )
    )

    await write_audit(
        db,
        action="expiry_batch_written_off",
        entity_type="expiry_batch",
        entity_id=str(batch.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        before={
            "batch_quantity": str(old_batch_quantity),
            "inventory_quantity": str(old_inventory_quantity),
        },
        after={
            "batch_quantity": str(batch.quantity),
            "inventory_quantity": str(inventory.quantity),
            "written_off": str(quantity),
            "reason": reason,
        },
    )
    await db.flush()
    return batch


def value_for(quantity: Decimal, cost_price: Decimal) -> Decimal:
    return (quantity * cost_price).quantize(Decimal("0.01"))


def today_utc() -> date:
    return datetime.now(UTC).date()
