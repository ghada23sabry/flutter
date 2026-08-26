"""Category intelligence service.

Provides smart category matching, suggestion, and creation for the
unknown product workflow.  Uses the existing Category model and
catalog_service patterns — no parallel category system.
"""
from __future__ import annotations

import logging
import uuid

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.audit import write_audit
from app.models.catalog import Category

logger = logging.getLogger(__name__)

# Common product-type → category mapping hints for suggestion.
_TYPE_CATEGORY_HINTS: dict[str, list[str]] = {
    "electronics": ["Electronics", "Technology", "Gadgets"],
    "phone": ["Electronics", "Mobile Phones", "Technology"],
    "tablet": ["Electronics", "Tablets", "Technology"],
    "laptop": ["Electronics", "Computers", "Technology"],
    "computer": ["Electronics", "Computers", "Technology"],
    "headphone": ["Electronics", "Audio", "Accessories"],
    "speaker": ["Electronics", "Audio", "Accessories"],
    "camera": ["Electronics", "Photography", "Technology"],
    "tv": ["Electronics", "Televisions", "Technology"],
    "monitor": ["Electronics", "Displays", "Technology"],
    "kitchen": ["Kitchen", "Kitchen Appliances", "Home"],
    "air fryer": ["Kitchen Appliances", "Kitchen", "Home"],
    "blender": ["Kitchen Appliances", "Kitchen", "Home"],
    "microwave": ["Kitchen Appliances", "Kitchen", "Home"],
    "coffee": ["Beverages", "Coffee", "Food & Drink"],
    "tea": ["Beverages", "Tea", "Food & Drink"],
    "snack": ["Snacks", "Food", "Food & Drink"],
    "chips": ["Snacks", "Food", "Food & Drink"],
    "candy": ["Sweets", "Food", "Food & Drink"],
    "chocolate": ["Sweets", "Food", "Food & Drink"],
    "bread": ["Bakery", "Food", "Food & Drink"],
    "milk": ["Dairy", "Food & Drink"],
    "cheese": ["Dairy", "Food & Drink"],
    "yogurt": ["Dairy", "Food & Drink"],
    "juice": ["Beverages", "Drinks", "Food & Drink"],
    "water": ["Beverages", "Drinks", "Food & Drink"],
    "soda": ["Beverages", "Soft Drinks", "Food & Drink"],
    "beer": ["Beverages", "Alcohol", "Food & Drink"],
    "wine": ["Beverages", "Alcohol", "Food & Drink"],
    "shampoo": ["Personal Care", "Beauty", "Health & Beauty"],
    "soap": ["Personal Care", "Hygiene", "Health & Beauty"],
    "toothpaste": ["Personal Care", "Oral Care", "Health & Beauty"],
    "cleaning": ["Household", "Cleaning", "Home"],
    "detergent": ["Household", "Cleaning", "Home"],
    "battery": ["Electronics", "Accessories", "Utilities"],
    "toy": ["Toys", "Kids", "Entertainment"],
    "book": ["Books", "Stationery", "Education"],
    "clothing": ["Clothing", "Fashion", "Apparel"],
    "shoe": ["Footwear", "Fashion", "Apparel"],
    "furniture": ["Furniture", "Home", "Home & Living"],
    "tool": ["Tools", "Hardware", "DIY"],
    "pet": ["Pet Supplies", "Pets", "Animal Care"],
    "medicine": ["Health", "Pharmacy", "Health & Wellness"],
    "vitamin": ["Health", "Supplements", "Health & Wellness"],
}


async def find_best_matching_category(
    db: AsyncSession,
    *,
    tenant_id: uuid.UUID,
    store_id: uuid.UUID,
    category_text: str | None,
) -> Category | None:
    """Find the best matching existing category for a text hint.

    Strategy:
    1. Exact case-insensitive name match
    2. Word-overlap scoring
    Returns None when no confident match exists.
    """
    if not category_text or not category_text.strip():
        return None

    normalised = category_text.strip().lower()

    # 1. Exact name match (case-insensitive)
    exact = (
        await db.execute(
            select(Category).where(
                Category.tenant_id == tenant_id,
                Category.store_id == store_id,
                Category.status == "active",
                func.lower(Category.name) == normalised,
            )
        )
    ).scalar_one_or_none()
    if exact is not None:
        return exact

    # 2. Word-overlap scoring
    categories = (
        await db.execute(
            select(Category).where(
                Category.tenant_id == tenant_id,
                Category.store_id == store_id,
                Category.status == "active",
            )
        )
    ).scalars().all()

    normalised_words = [w for w in normalised.split() if len(w) >= 2]
    if not normalised_words:
        return None

    best_cat: Category | None = None
    best_score = 0
    for cat in categories:
        cat_lower = cat.name.lower()
        # Containment bonus
        score = 0
        if normalised in cat_lower or cat_lower in normalised:
            score += 3
        cat_words = [w for w in cat_lower.split() if len(w) >= 2]
        score += sum(1 for w in normalised_words if w in cat_words)
        if score > best_score:
            best_score = score
            best_cat = cat

    # Require at least 2 matching words or strong containment
    if best_score >= 2 and best_cat is not None:
        return best_cat
    return None


def suggest_category_name(product_name: str | None, category_text: str | None) -> str | None:
    """Suggest a category name based on the product name and detected category.

    Uses the _TYPE_CATEGORY_HINTS mapping to suggest an appropriate category.
    Returns None when no suggestion can be made.
    """
    texts = " ".join(filter(None, [category_text, product_name])).lower()
    if not texts:
        return None

    # Check hints from most specific to least specific
    for keyword, suggestions in _TYPE_CATEGORY_HINTS.items():
        if keyword in texts:
            return suggestions[0]

    # If category text was detected (e.g. from AI), use it directly
    if category_text and category_text.strip():
        return category_text.strip()

    return None


async def create_category_if_accepted(
    db: AsyncSession,
    *,
    tenant_id: uuid.UUID,
    store_id: uuid.UUID,
    category_name: str,
    actor_id: uuid.UUID | None,
) -> Category:
    """Create a new category if the user accepts the suggestion.

    Checks for near-duplicates (case-insensitive name) before creating.
    Returns the new or existing category.
    """
    normalised = category_name.strip()
    if not normalised:
        raise ValueError("Category name cannot be empty")

    # Check for near-duplicate
    existing = (
        await db.execute(
            select(Category).where(
                Category.tenant_id == tenant_id,
                Category.store_id == store_id,
                Category.status == "active",
                func.lower(Category.name) == normalised.lower(),
            )
        )
    ).scalar_one_or_none()
    if existing is not None:
        return existing

    category = Category(
        tenant_id=tenant_id,
        store_id=store_id,
        name=normalised,
        status="active",
    )
    db.add(category)
    await db.flush()
    await write_audit(
        db,
        action="category_created",
        entity_type="category",
        entity_id=str(category.id),
        tenant_id=tenant_id,
        store_id=store_id,
        user_id=actor_id,
        after={"name": category.name},
    )
    await db.commit()
    await db.refresh(category)
    return category
