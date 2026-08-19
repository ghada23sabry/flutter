import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import CODE_NOT_FOUND, CODE_VALIDATION_ERROR, AppError
from app.core.security import AuthContext
from app.models import Category, Product, Store, Supplier


def clean_required(value: str, field: str) -> str:
    """Strip whitespace and reject values that would collapse to empty.

    Pydantic min_length validates the raw payload, so a whitespace-only string
    (" ") passes but would store an empty, unusable value.
    """
    cleaned = value.strip()
    if not cleaned:
        raise AppError(CODE_VALIDATION_ERROR, f"{field} must not be blank", 422)
    return cleaned


def normalize_barcode(value: str | None) -> str | None:
    """Normalize an external barcode/QR payload before storage or lookup.

    Barcodes are stored in canonical form: trimmed, internal whitespace
    collapsed, uppercased (QR payloads may carry alphanumerics). Lookups must
    run the same normalization so the scanner input always matches.
    """
    if value is None:
        return None
    normalized = " ".join(value.split()).upper()
    return normalized or None


def require_store(ctx: AuthContext, store_id: uuid.UUID) -> Store:
    """Return the store if it is in the authenticated context, else 404."""
    store = next((s for s in ctx.accessible_stores if s.id == store_id), None)
    if store is None:
        raise AppError(CODE_NOT_FOUND, "Store not found", 404)
    return store


async def get_scoped_product(
    db: AsyncSession, ctx: AuthContext, store_id: uuid.UUID, product_id: uuid.UUID
) -> Product:
    require_store(ctx, store_id)
    product = (
        await db.execute(
            select(Product).where(
                Product.id == product_id,
                Product.tenant_id == ctx.tenant.id,
                Product.store_id == store_id,
            )
        )
    ).scalar_one_or_none()
    if product is None:
        raise AppError(CODE_NOT_FOUND, "Product not found", 404)
    return product


async def get_scoped_category(
    db: AsyncSession, ctx: AuthContext, store_id: uuid.UUID, category_id: uuid.UUID
) -> Category:
    require_store(ctx, store_id)
    category = (
        await db.execute(
            select(Category).where(
                Category.id == category_id,
                Category.tenant_id == ctx.tenant.id,
                Category.store_id == store_id,
            )
        )
    ).scalar_one_or_none()
    if category is None:
        raise AppError(CODE_NOT_FOUND, "Category not found", 404)
    return category


async def get_scoped_supplier(
    db: AsyncSession, ctx: AuthContext, supplier_id: uuid.UUID
) -> Supplier:
    supplier = (
        await db.execute(
            select(Supplier).where(
                Supplier.id == supplier_id,
                Supplier.tenant_id == ctx.tenant.id,
            )
        )
    ).scalar_one_or_none()
    if supplier is None:
        raise AppError(CODE_NOT_FOUND, "Supplier not found", 404)
    return supplier
