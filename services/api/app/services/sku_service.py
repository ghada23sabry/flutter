"""SKU auto-generation service.

Generates unique SKUs per tenant/store using configurable templates.
Uses atomic SELECT FOR UPDATE to prevent counter races under concurrency.
"""
import uuid

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import SkuSetting


async def get_or_create_sku_setting(
    db: AsyncSession,
    tenant_id: uuid.UUID,
    store_id: uuid.UUID,
) -> SkuSetting:
    """Return existing SKU setting or create defaults."""
    setting = (
        await db.execute(
            select(SkuSetting).where(
                SkuSetting.tenant_id == tenant_id,
                SkuSetting.store_id == store_id,
            )
        )
    ).scalar_one_or_none()
    if setting is None:
        setting = SkuSetting(
            tenant_id=tenant_id,
            store_id=store_id,
            prefix="SKU",
            separator="-",
            counter_length=5,
            next_counter=1,
            category_prefix=False,
        )
        db.add(setting)
        await db.flush()
    return setting


async def generate_sku(
    db: AsyncSession,
    tenant_id: uuid.UUID,
    store_id: uuid.UUID,
    category_code: str | None = None,
) -> str:
    """Generate next unique SKU for (tenant, store).

    Format: {prefix}{separator}{category_code?}{separator}{counter:0N}

    The counter is incremented atomically using SELECT FOR UPDATE to prevent
    duplicate SKUs under concurrent product creation.
    """
    setting = await get_or_create_sku_setting(db, tenant_id, store_id)

    # Lock the row for update to prevent race conditions
    locked = (
        await db.execute(
            select(SkuSetting)
            .where(SkuSetting.id == setting.id)
            .with_for_update()
        )
    ).scalar_one()

    parts = [locked.prefix]
    if locked.category_prefix and category_code:
        parts.append(category_code.upper())
    counter_str = str(locked.next_counter).zfill(locked.counter_length)
    parts.append(counter_str)

    sku = locked.separator.join(parts)

    # Atomically increment counter
    await db.execute(
        update(SkuSetting)
        .where(SkuSetting.id == locked.id)
        .values(next_counter=SkuSetting.next_counter + 1)
    )
    await db.flush()

    return sku
