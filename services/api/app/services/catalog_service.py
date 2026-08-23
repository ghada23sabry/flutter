import re
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


def normalize_product_name(name: str) -> str:
    """Normalize a product name for recognition memory lookups.

    Lowercases, strips leading/trailing whitespace, collapses internal
    whitespace, and removes common punctuation characters that vision
    models may inconsistently include or omit.
    """
    text = name.strip().lower()
    text = re.sub(r"[^\w\s]", "", text)
    text = " ".join(text.split())
    return text


def normalize_category_text(text: str) -> str:
    """Normalize category text for matching.

    Lowercases, strips, collapses whitespace, removes trailing plurals
    and common suffixes that vision models may add inconsistently.
    """
    cleaned = text.strip().lower()
    cleaned = " ".join(cleaned.split())
    return cleaned


async def resolve_category_by_text(
    db: AsyncSession,
    tenant_id: uuid.UUID,
    store_id: uuid.UUID,
    category_text: str,
) -> uuid.UUID | None:
    """Resolve a category text string to an existing category UUID within scope.

    Strategy:
    1. Exact case-insensitive name match
    2. Best fuzzy match (word overlap or containment)

    Returns the category UUID if a confident match is found, None otherwise.
    The caller decides what to do with unmatched categories.
    """
    normalized = normalize_category_text(category_text)
    if not normalized:
        return None

    # 1. Exact name match (case-insensitive)
    exact = (
        await db.execute(
            select(Category.id).where(
                Category.tenant_id == tenant_id,
                Category.store_id == store_id,
                Category.name.ilike(normalized),
                Category.status == "active",
            )
        )
    ).scalar_one_or_none()
    if exact is not None:
        return exact

    # 2. Fuzzy match — fetch active categories and score
    categories = (
        await db.execute(
            select(Category).where(
                Category.tenant_id == tenant_id,
                Category.store_id == store_id,
                Category.status == "active",
            )
        )
    ).scalars().all()
    if not categories:
        return None

    best_category: Category | None = None
    best_score = 0
    for cat in categories:
        cat_name = cat.name.lower()
        # Exact containment
        if normalized == cat_name:
            return cat.id
        if normalized in cat_name or cat_name in normalized:
            score = 10
        else:
            # Word overlap
            norm_words = [w for w in normalized.split() if len(w) >= 2]
            cat_words = [w for w in cat_name.split() if len(w) >= 2]
            if not norm_words or not cat_words:
                continue
            matches = sum(1 for w in norm_words if w in cat_words)
            score = matches
        if score > best_score and score >= 1:
            best_score = score
            best_category = cat

    return best_category.id if best_category is not None else None
