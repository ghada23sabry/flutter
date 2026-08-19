import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.audit import write_audit
from app.core.db import get_db
from app.core.errors import CODE_CONFLICT, CODE_VALIDATION_ERROR, AppError
from app.core.security import AuthContext, require_permission
from app.models import Category
from app.schemas import CategoryIn, CategoryOut, CategoryUpdate
from app.services.catalog_service import clean_required, get_scoped_category, require_store

router = APIRouter(prefix="/categories", tags=["catalog"])

PERMISSION_VIEW = "categories.view"
PERMISSION_MANAGE = "categories.manage"


@router.get("", response_model=list[CategoryOut])
async def list_categories(
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
    status: Annotated[str | None, Query(pattern="^(active|inactive)$")] = None,
):
    require_store(ctx, store_id)
    query = select(Category).where(
        Category.tenant_id == ctx.tenant.id,
        Category.store_id == store_id,
    )
    if status:
        query = query.where(Category.status == status)
    categories = (await db.execute(query.order_by(Category.name.asc()))).scalars().all()
    return [CategoryOut.model_validate(c) for c in categories]


@router.post("", response_model=CategoryOut, status_code=201)
async def create_category(
    body: CategoryIn,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_MANAGE))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    if body.parent_id is not None:
        await get_scoped_category(db, ctx, store_id, body.parent_id)
    category = Category(
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        parent_id=body.parent_id,
        name=clean_required(body.name, "name"),
        code=body.code.strip().upper() if body.code else None,
    )
    db.add(category)
    try:
        await db.flush()
    except IntegrityError as exc:
        await db.rollback()
        raise AppError(CODE_CONFLICT, "A category with this code already exists in this store", 409) from exc
    await write_audit(
        db,
        action="category_created",
        entity_type="category",
        entity_id=str(category.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        after={"name": category.name, "code": category.code},
    )
    await db.commit()
    await db.refresh(category)
    return CategoryOut.model_validate(category)


@router.get("/{category_id}", response_model=CategoryOut)
async def get_category(
    category_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    category = await get_scoped_category(db, ctx, store_id, category_id)
    return CategoryOut.model_validate(category)


@router.patch("/{category_id}", response_model=CategoryOut)
async def update_category(
    category_id: uuid.UUID,
    body: CategoryUpdate,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_MANAGE))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    category = await get_scoped_category(db, ctx, store_id, category_id)
    before = {"name": category.name, "status": category.status}
    updates = body.model_dump(exclude_unset=True)
    if "name" in updates and updates["name"] is not None:
        category.name = clean_required(updates["name"], "name")
    if "code" in updates:
        category.code = updates["code"].strip().upper() if updates["code"] else None
    if "parent_id" in updates:
        if updates["parent_id"] is not None:
            if updates["parent_id"] == category.id:
                raise AppError(CODE_VALIDATION_ERROR, "A category cannot be its own parent", 422)
            await get_scoped_category(db, ctx, store_id, updates["parent_id"])
        category.parent_id = updates["parent_id"]
    if "status" in updates and updates["status"] is not None:
        category.status = updates["status"]
    try:
        await db.flush()
    except IntegrityError as exc:
        await db.rollback()
        raise AppError(CODE_CONFLICT, "A category with this code already exists in this store", 409) from exc
    await write_audit(
        db,
        action="category_updated",
        entity_type="category",
        entity_id=str(category.id),
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        user_id=ctx.user.id,
        before=before,
        after={"name": category.name, "status": category.status},
    )
    await db.commit()
    await db.refresh(category)
    return CategoryOut.model_validate(category)
