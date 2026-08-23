"""M4-A.5 — HTTP API for the AI scan domain (thin router).

Exposes the M4-A service-layer capabilities through HTTP with the seeded RBAC
permissions. No inventory, no AI and no direct database-mutation logic lives
here — every write path is delegated to `app.services.ai_service`, and the
vision adapter is injected through the `AIVisionPort` composition root
(`app.ai.get_vision_port`), which is the only place that names a concrete
adapter.

Permission mapping (one permission per endpoint, never broadened):
    POST /ai/scans                       → ai.scan
    POST /ai/scans/{id}/process          → ai.scan
    GET  /ai/scans/{id}                  → ai.view
    GET  /ai/scans/{id}/detections       → ai.view
    GET  /ai/scans/{id}/reconciliations  → ai.view
    PATCH /ai/scans/{id}/reconciliations/{rid} → ai.reconcile
    POST /ai/scans/{id}/confirm          → ai.confirm
"""

import uuid
from typing import Annotated

from fastapi import APIRouter, Body, Depends, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai import get_vision_port
from app.ai.vision_port import AIVisionPort
from app.core.db import get_db
from app.core.errors import CODE_NOT_FOUND, CODE_VALIDATION_ERROR, AppError
from app.core.security import AuthContext, require_permission
from app.models import Product, ScanDetection, ScanReconciliation, ScanSession
from app.schemas import (
    DetectionLink,
    DetectionOut,
    ReconciliationOut,
    ReconciliationUpdate,
    ScanSessionCreate,
    ScanSessionOut,
)
from app.services.ai_service import (
    confirm_scan_session,
    create_scan_session,
    link_detection_to_product,
    process_scan,
    update_reconciliation,
)
from app.services.catalog_service import require_store

router = APIRouter(prefix="/ai", tags=["ai"])

PERMISSION_SCAN = "ai.scan"
PERMISSION_VIEW = "ai.view"
PERMISSION_RECONCILE = "ai.reconcile"
PERMISSION_CONFIRM = "ai.confirm"

# Largest accepted scan-image payload (bytes). Images are never persisted.
MAX_IMAGE_BYTES = 20 * 1024 * 1024


def get_vision_port_dependency() -> AIVisionPort:
    """FastAPI dependency over the composition root (overridable in tests)."""
    return get_vision_port()


async def _get_scoped_session(
    db: AsyncSession, ctx: AuthContext, store_id: uuid.UUID, session_id: uuid.UUID
) -> ScanSession:
    require_store(ctx, store_id)
    session = (
        await db.execute(
            select(ScanSession).where(
                ScanSession.id == session_id,
                ScanSession.tenant_id == ctx.tenant.id,
                ScanSession.store_id == store_id,
            )
        )
    ).scalar_one_or_none()
    if session is None:
        raise AppError(CODE_NOT_FOUND, "Scan session not found", 404)
    return session


@router.post("/scans", response_model=ScanSessionOut, status_code=201)
async def create_scan(
    body: ScanSessionCreate,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_SCAN))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    session = await create_scan_session(
        db,
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        actor_id=ctx.user.id,
        shelf_id=body.shelf_id,
        operation=body.operation,
        note=body.note,
    )
    return ScanSessionOut.model_validate(session)


@router.post("/scans/{session_id}/process", response_model=ScanSessionOut)
async def process_scan_endpoint(
    session_id: uuid.UUID,
    image: Annotated[bytes, Body(...)],
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_SCAN))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
    vision_port: Annotated[AIVisionPort, Depends(get_vision_port_dependency)],
):
    require_store(ctx, store_id)
    if len(image) > MAX_IMAGE_BYTES:
        raise AppError(CODE_VALIDATION_ERROR, "Scan image is too large", 422)
    session = await process_scan(
        db,
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        session_id=session_id,
        actor_id=ctx.user.id,
        image=image,
        vision_port=vision_port,
    )
    return ScanSessionOut.model_validate(session)


@router.get("/scans/{session_id}", response_model=ScanSessionOut)
async def get_scan(
    session_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    return ScanSessionOut.model_validate(await _get_scoped_session(db, ctx, store_id, session_id))


@router.get("/scans/{session_id}/detections", response_model=list[DetectionOut])
async def get_scan_detections(
    session_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    await _get_scoped_session(db, ctx, store_id, session_id)
    rows = (
        await db.execute(
            select(ScanDetection, Product)
            .outerjoin(Product, ScanDetection.product_id == Product.id)
            .where(
                ScanDetection.session_id == session_id,
                ScanDetection.tenant_id == ctx.tenant.id,
                ScanDetection.store_id == store_id,
            )
            .order_by(ScanDetection.created_at)
        )
    ).all()
    return [
        DetectionOut.model_validate(det).model_copy(
            update={
                "product_name": product.name if product else None,
                "product_sku": product.sku if product else None,
                "product_barcode": product.barcode if product else None,
            }
        )
        for det, product in rows
    ]


@router.post(
    "/scans/{session_id}/detections/{detection_id}/link",
    response_model=DetectionOut,
)
async def link_detection(
    session_id: uuid.UUID,
    detection_id: uuid.UUID,
    body: DetectionLink,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_RECONCILE))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    detection = await link_detection_to_product(
        db,
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        session_id=session_id,
        detection_id=detection_id,
        product_id=body.product_id,
        actor_id=ctx.user.id,
    )
    product = (
        await db.execute(select(Product).where(Product.id == detection.product_id))
    ).scalar_one_or_none()
    return DetectionOut.model_validate(detection).model_copy(
        update={
            "product_name": product.name if product else None,
            "product_sku": product.sku if product else None,
            "product_barcode": product.barcode if product else None,
        }
    )


@router.get("/scans/{session_id}/reconciliations", response_model=list[ReconciliationOut])
async def get_scan_reconciliations(
    session_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    await _get_scoped_session(db, ctx, store_id, session_id)
    rows = (
        await db.execute(
            select(ScanReconciliation, Product)
            .join(Product, ScanReconciliation.product_id == Product.id)
            .where(
                ScanReconciliation.session_id == session_id,
                ScanReconciliation.tenant_id == ctx.tenant.id,
                ScanReconciliation.store_id == store_id,
            )
            .order_by(ScanReconciliation.product_id)
        )
    ).all()
    return [
        ReconciliationOut.model_validate(rec).model_copy(update={"product_name": product.name, "sku": product.sku})
        for rec, product in rows
    ]


@router.patch("/scans/{session_id}/reconciliations/{reconciliation_id}", response_model=ReconciliationOut)
async def update_reconciliation_endpoint(
    session_id: uuid.UUID,
    reconciliation_id: uuid.UUID,
    body: ReconciliationUpdate,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_RECONCILE))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    rec = await update_reconciliation(
        db,
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        session_id=session_id,
        reconciliation_id=reconciliation_id,
        actor_id=ctx.user.id,
        resolution=body.resolution,
        detected_quantity=body.detected_quantity,
    )
    product = (await db.execute(select(Product).where(Product.id == rec.product_id))).scalar_one()
    return ReconciliationOut.model_validate(rec).model_copy(update={"product_name": product.name, "sku": product.sku})


@router.post("/scans/{session_id}/confirm", response_model=ScanSessionOut)
async def confirm_scan(
    session_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_CONFIRM))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    require_store(ctx, store_id)
    session = await confirm_scan_session(
        db,
        tenant_id=ctx.tenant.id,
        store_id=store_id,
        session_id=session_id,
        actor_id=ctx.user.id,
    )
    return ScanSessionOut.model_validate(session)
