"""Scan service lifecycle (M4-A.3 + M4-A.4).

create_scan_session → PROCESSING
process_scan       → injected AIVisionPort → tenant/store-scoped product
                     resolution → persist detections → deterministic aggregation
                     → reconciliation vs inventory → COMPLETED | NEEDS_REVIEW
                     (FAILED when vision processing raises).
confirm_scan_session → the ONLY path that mutates inventory from a scan:
                     explicit authenticated confirmation that applies the
                     reconciled quantities as stock movements (COUNT for
                     count, PURCHASE for receive, SALE for sale — all existing
                     vocabulary) in ONE atomic transaction (M4-A.4 + first-release
                     sprint).

Hard rules enforced here:
- The service depends on the `AIVisionPort` PROTOCOL only — it never imports the
  mock or any concrete adapter.
- NO inventory mutation and NO StockMovement rows are written during scanning;
  the only stock write happens on explicit confirmation (M4-A.4).
- Product resolution (sku/barcode → product) is scoped to (tenant, store).
- The shelf on a session must belong to that store and tenant.
- Aggregation is keyed by product and summed with exact Decimal arithmetic, so
  item order never changes the result.
- Processing is protected against duplicates: the session row is locked with
  FOR UPDATE and only a `processing` session may be processed.
- Confirmation is protected against duplicates, races and stale counts: the
  session row is locked FOR UPDATE, only COMPLETED/NEEDS_REVIEW sessions are
  confirmable, affected inventory rows are locked in deterministic product
  order, and each reconciliation's recorded `system_quantity` is re-checked
  against the locked current quantity before anything is written.
- Scan images are never persisted and never logged.
"""

import uuid
from datetime import UTC, datetime
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai.contract import DetectedItem, VisionContext
from app.ai.vision_port import AIVisionPort
from app.config import get_settings
from app.core.audit import write_audit
from app.core.errors import CODE_CONFLICT, CODE_INTERNAL_ERROR, CODE_NOT_FOUND, CODE_VALIDATION_ERROR, AppError
from app.models import (
    Inventory,
    Product,
    ScanDetection,
    ScanReconciliation,
    ScanSession,
    Shelf,
    StockMovement,
    Store,
)
from app.services.catalog_service import normalize_barcode

SESSION_STATUS_PROCESSING = "processing"
SESSION_STATUS_COMPLETED = "completed"
SESSION_STATUS_NEEDS_REVIEW = "needs_review"
SESSION_STATUS_CONFIRMED = "confirmed"
SESSION_STATUS_CANCELLED = "cancelled"
SESSION_STATUS_FAILED = "failed"

# Business operation of a scan session. The movement vocabulary is untouched —
# count writes COUNT, receive writes PURCHASE, sale writes SALE (both already in
# the movement enum); the operation only decides WHICH existing type is written
# and HOW the detected quantity is applied (replace / add / subtract).
SCAN_OPERATION_COUNT = "count"
SCAN_OPERATION_RECEIVE = "receive"
SCAN_OPERATION_SALE = "sale"
SCAN_OPERATIONS = {SCAN_OPERATION_COUNT, SCAN_OPERATION_RECEIVE, SCAN_OPERATION_SALE}

# Only a settled, non-failed, non-cancelled session may be confirmed. PROCESSING
# (not scanned yet) and already-CONFIRMED sessions are rejected.
CONFIRMABLE_STATUSES = {SESSION_STATUS_COMPLETED, SESSION_STATUS_NEEDS_REVIEW}

RECONCILIATION_NO_CHANGE = "no_change"
RECONCILIATION_NEEDS_REVIEW = "needs_review"
RECONCILIATION_APPLIED = "applied"

RECONCILIATION_RESOLUTION_APPLY = "apply"
RECONCILIATION_RESOLUTION_IGNORE = "ignore"

DETECTION_ACCEPTED = "accepted"
DETECTION_NEEDS_REVIEW = "needs_review"

MOVEMENT_TYPE_COUNT = "COUNT"
MOVEMENT_TYPE_PURCHASE = "PURCHASE"
MOVEMENT_TYPE_SALE = "SALE"
REFERENCE_TYPE_SCAN_SESSION = "SCAN_SESSION"

# Movement written at confirmation for each scan operation.
OPERATION_MOVEMENT_TYPE = {
    SCAN_OPERATION_COUNT: MOVEMENT_TYPE_COUNT,
    SCAN_OPERATION_RECEIVE: MOVEMENT_TYPE_PURCHASE,
    SCAN_OPERATION_SALE: MOVEMENT_TYPE_SALE,
}

OPERATION_MOVEMENT_NOTES = {
    SCAN_OPERATION_COUNT: "Confirmed scan count",
    SCAN_OPERATION_RECEIVE: "Confirmed stock receiving",
    SCAN_OPERATION_SALE: "Confirmed quick sale",
}


class ScanProcessingFailed(AppError):
    """Raised after a failed vision call; the session is persisted as FAILED."""

    def __init__(self) -> None:
        super().__init__(CODE_INTERNAL_ERROR, "Vision processing failed", 500)


def _utcnow() -> datetime:
    return datetime.now(UTC)


async def create_scan_session(
    db: AsyncSession,
    *,
    tenant_id: uuid.UUID,
    store_id: uuid.UUID,
    actor_id: uuid.UUID | None = None,
    shelf_id: uuid.UUID | None = None,
    operation: str = SCAN_OPERATION_COUNT,
    note: str | None = None,
) -> ScanSession:
    """Open a scan session in PROCESSING state. Scope-validates store + shelf."""
    if operation not in SCAN_OPERATIONS:
        raise AppError(CODE_VALIDATION_ERROR, "Unknown scan operation", 422)

    store = (
        await db.execute(select(Store).where(Store.id == store_id, Store.tenant_id == tenant_id))
    ).scalar_one_or_none()
    if store is None:
        raise AppError(CODE_NOT_FOUND, "Store not found", 404)

    if shelf_id is not None:
        shelf = (
            await db.execute(
                select(Shelf).where(Shelf.id == shelf_id, Shelf.tenant_id == tenant_id, Shelf.store_id == store_id)
            )
        ).scalar_one_or_none()
        if shelf is None:
            raise AppError(CODE_NOT_FOUND, "Shelf not found", 404)

    session = ScanSession(
        tenant_id=tenant_id,
        store_id=store_id,
        shelf_id=shelf_id,
        status=SESSION_STATUS_PROCESSING,
        operation=operation,
        note=note,
        started_by=actor_id,
    )
    db.add(session)
    await db.commit()
    return session


async def process_scan(
    db: AsyncSession,
    *,
    tenant_id: uuid.UUID,
    store_id: uuid.UUID,
    session_id: uuid.UUID,
    actor_id: uuid.UUID | None,
    image: bytes,
    vision_port: AIVisionPort,
) -> ScanSession:
    """Run the scan pipeline for one image on a PROCESSING session.

    Idempotency/duplicate protection: the session row is locked (FOR UPDATE) and
    a non-PROCESSING status is rejected with 409, so a session is processed
    exactly once. A vision failure is persisted deterministically as FAILED.
    """
    session = (
        await db.execute(
            select(ScanSession).where(
                ScanSession.id == session_id,
                ScanSession.tenant_id == tenant_id,
                ScanSession.store_id == store_id,
            )
            .with_for_update()
        )
    ).scalar_one_or_none()
    if session is None:
        raise AppError(CODE_NOT_FOUND, "Scan session not found", 404)
    if session.status != SESSION_STATUS_PROCESSING:
        raise AppError(CODE_CONFLICT, "Scan session is not in processing state", 409)

    context = VisionContext(tenant_id=tenant_id, store_id=store_id, shelf_id=session.shelf_id)
    try:
        items = await vision_port.analyze_image(image, context)
    except Exception as exc:
        session.status = SESSION_STATUS_FAILED
        session.completed_at = _utcnow()
        session.completed_by = actor_id
        await db.commit()
        raise ScanProcessingFailed() from exc

    resolved: list[tuple[uuid.UUID | None, DetectedItem, str]] = []
    for item in items:
        product = await _resolve_product(db, tenant_id, store_id, item)
        product_id = product.id if product is not None else None
        status = _detection_status(item, product_id)
        db.add(
            ScanDetection(
                tenant_id=tenant_id,
                store_id=store_id,
                session_id=session.id,
                method=item.method,
                detected_sku=item.detected_sku,
                detected_barcode=item.detected_barcode,
                product_id=product_id,
                confidence=item.confidence,
                quantity_detected=item.quantity,
                status=status,
                meta=item.meta,
                created_by=actor_id,
            )
        )
        resolved.append((product_id, item, status))

    totals = _aggregate(resolved)
    for product_id in sorted(totals):
        detected = totals[product_id]
        inventory = (
            await db.execute(
                select(Inventory).where(Inventory.store_id == store_id, Inventory.product_id == product_id)
            )
        ).scalar_one_or_none()
        system_quantity = inventory.quantity if inventory is not None else Decimal(0)
        # `variance` IS the delta confirmation will apply. count replaces the
        # shelf quantity (detected − system); receive adds the detected amount
        # (+detected); sale subtracts it (−detected).
        variance = _variance_for(session.operation, detected, system_quantity)
        db.add(
            ScanReconciliation(
                tenant_id=tenant_id,
                store_id=store_id,
                session_id=session.id,
                product_id=product_id,
                detected_quantity=detected,
                system_quantity=system_quantity,
                variance=variance,
                status=RECONCILIATION_NO_CHANGE if variance == 0 else RECONCILIATION_NEEDS_REVIEW,
            )
        )

    session.status = (
        SESSION_STATUS_NEEDS_REVIEW
        if any(product_id is None or status == DETECTION_NEEDS_REVIEW for product_id, _, status in resolved)
        else SESSION_STATUS_COMPLETED
    )
    session.completed_at = _utcnow()
    session.completed_by = actor_id
    session.image_count = 1
    await db.commit()
    return session


async def update_reconciliation(
    db: AsyncSession,
    *,
    tenant_id: uuid.UUID,
    store_id: uuid.UUID,
    session_id: uuid.UUID,
    reconciliation_id: uuid.UUID,
    actor_id: uuid.UUID | None,
    resolution: str,
    detected_quantity: Decimal | None = None,
) -> ScanReconciliation:
    """Record a human review decision for one reconciliation row (M4-A.6).

    This is the ONLY place that mutates a reconciliation before confirmation.
    It changes review state, never inventory: applying/ignoring/overriding
    decides what `confirm_scan_session` will (or will not) write as COUNT
    movements, but the confirmation safety mechanisms are untouched — the
    session lock, deterministic inventory locking, stale `system_quantity`
    re-check, duplicate protection and atomic rollback all still run exactly
    as before.

    Scope rules:
    - The session must belong to (tenant, store) → 404 otherwise.
    - The reconciliation must belong to that session AND (tenant, store) → 404
      otherwise (covers wrong-scan, wrong-tenant and wrong-store relationships).
    - Only an open, confirmable scan may be reviewed: PROCESSING (not scanned
      yet), CONFIRMED, FAILED and CANCELLED sessions are rejected with 409.
    - `resolution` must be apply|ignore and, when applying, `detected_quantity`
      (if given) must be a valid non-negative decimal — enforced by the schema
      and re-checked here.
    """
    session = (
        await db.execute(
            select(ScanSession)
            .where(
                ScanSession.id == session_id,
                ScanSession.tenant_id == tenant_id,
                ScanSession.store_id == store_id,
            )
            .with_for_update()
        )
    ).scalar_one_or_none()
    if session is None:
        raise AppError(CODE_NOT_FOUND, "Scan session not found", 404)
    if session.status not in CONFIRMABLE_STATUSES:
        raise AppError(CODE_CONFLICT, "Scan session is not open for review in its current state", 409)

    rec = (
        await db.execute(
            select(ScanReconciliation)
            .where(
                ScanReconciliation.id == reconciliation_id,
                ScanReconciliation.session_id == session_id,
                ScanReconciliation.tenant_id == tenant_id,
                ScanReconciliation.store_id == store_id,
            )
            .with_for_update()
        )
    ).scalar_one_or_none()
    if rec is None:
        raise AppError(CODE_NOT_FOUND, "Reconciliation not found", 404)

    before = {
        "resolution": rec.resolution,
        "detected_quantity": str(rec.detected_quantity),
        "system_quantity": str(rec.system_quantity),
        "variance": str(rec.variance),
    }

    rec.resolution = resolution
    if detected_quantity is not None:
        if detected_quantity < 0:
            raise AppError(CODE_VALIDATION_ERROR, "detected_quantity must be zero or positive", 422)
        rec.detected_quantity = detected_quantity
        rec.variance = _variance_for(session.operation, detected_quantity, rec.system_quantity)
        rec.status = RECONCILIATION_NO_CHANGE if rec.variance == 0 else RECONCILIATION_NEEDS_REVIEW

    after = {
        "resolution": rec.resolution,
        "detected_quantity": str(rec.detected_quantity),
        "system_quantity": str(rec.system_quantity),
        "variance": str(rec.variance),
    }

    await write_audit(
        db,
        action="reconciliation_updated",
        entity_type="scan_reconciliation",
        entity_id=str(rec.id),
        tenant_id=tenant_id,
        store_id=store_id,
        user_id=actor_id,
        before=before,
        after=after,
    )
    await db.commit()
    await db.refresh(rec)
    return rec


async def confirm_scan_session(
    db: AsyncSession,
    *,
    tenant_id: uuid.UUID,
    store_id: uuid.UUID,
    session_id: uuid.UUID,
    actor_id: uuid.UUID | None,
) -> ScanSession:
    """Explicitly confirm a scan and apply its reconciled counts to stock.

    This is the ONLY path that turns an AI scan into an inventory change. The
    whole confirmation runs in ONE database transaction:

    1. Lock the session row (FOR UPDATE). A session must belong to (tenant,
       store) → 404 otherwise; its status must be COMPLETED or NEEDS_REVIEW →
       PROCESSING / FAILED / CANCELLED / already-CONFIRMED sessions are 409.
    2. Load the session's reconciliations (scoped, ordered by product_id).
    3. Lock every affected inventory row in deterministic product order
       (reuses the M2/M3 `FOR UPDATE` concurrency mechanism).
    4. Re-check each reconciliation's recorded `system_quantity` against the
       locked current quantity — a stale scan (inventory changed after it was
       processed) is rejected with 409 before anything is written.
    5. Apply: per the session operation, reconcile to the target quantity
       (count → replace with detected; receive → add detected; sale → subtract
       detected, rejecting when stock would go negative), bump
       `inventory.version`, write one StockMovement per affected product (COUNT
       / PURCHASE / SALE, all existing movement vocabulary), mark the
       reconciliation applied, mark the session confirmed, write the audit row.
       Zero-variance reconciliations are marked applied but write no movement;
       reconciliations resolved to "ignore" are skipped.
    6. Commit. Any failure (stale check, integrity error, unexpected error)
       rolls everything back — nothing is partially persisted.

    Duplicate confirmation is impossible: a CONFIRMED session is outside
    CONFIRMABLE_STATUSES, and the session row lock serializes concurrent
    confirmations (the second one observes CONFIRMED → 409). A partial unique
    index (migration 0008) additionally forbids a second movement for the same
    (store, product, scan session) at the database level for every operation.
    """
    try:
        session = (
            await db.execute(
                select(ScanSession)
                .where(
                    ScanSession.id == session_id,
                    ScanSession.tenant_id == tenant_id,
                    ScanSession.store_id == store_id,
                )
                .with_for_update()
            )
        ).scalar_one_or_none()
        if session is None:
            raise AppError(CODE_NOT_FOUND, "Scan session not found", 404)
        if session.status not in CONFIRMABLE_STATUSES:
            raise AppError(CODE_CONFLICT, "Scan session is not confirmable in its current state", 409)

        reconciliations = (
            await db.execute(
                select(ScanReconciliation)
                .where(
                    ScanReconciliation.session_id == session_id,
                    ScanReconciliation.tenant_id == tenant_id,
                    ScanReconciliation.store_id == store_id,
                )
                .order_by(ScanReconciliation.product_id)
            )
        ).scalars().all()

        # Deterministic lock order: one row per product, ascending by product_id.
        # Every inventory row the confirmation may write is locked up front so no
        # concurrent write can slip between the staleness check and the apply.
        locks: dict[uuid.UUID, Inventory | None] = {}
        for rec in reconciliations:
            if rec.resolution == RECONCILIATION_RESOLUTION_IGNORE:
                continue
            locks[rec.product_id] = (
                await db.execute(
                    select(Inventory)
                    .where(Inventory.store_id == store_id, Inventory.product_id == rec.product_id)
                    .with_for_update()
                )
            ).scalar_one_or_none()

        now = _utcnow()
        applied: list[dict] = []
        for rec in reconciliations:
            if rec.resolution == RECONCILIATION_RESOLUTION_IGNORE:
                continue
            current = locks[rec.product_id]
            current_quantity = current.quantity if current is not None else Decimal(0)
            if current_quantity != rec.system_quantity:
                raise AppError(
                    CODE_CONFLICT,
                    "Inventory changed since this scan was processed; re-run the scan before confirming",
                    409,
                )

            if rec.variance == 0:
                rec.status = RECONCILIATION_APPLIED
                rec.resolution = RECONCILIATION_RESOLUTION_APPLY
                rec.confirmed_by = actor_id
                rec.confirmed_at = now
                continue

            # Per-operation target quantity. count replaces the shelf quantity,
            # receive adds the detected amount, sale subtracts it. `delta` is
            # the movement's signed quantity change (equals `rec.variance`).
            if session.operation == SCAN_OPERATION_RECEIVE:
                new_quantity = current_quantity + rec.detected_quantity
            elif session.operation == SCAN_OPERATION_SALE:
                new_quantity = current_quantity - rec.detected_quantity
                if new_quantity < 0:
                    raise AppError(
                        CODE_VALIDATION_ERROR,
                        "Insufficient stock for this sale; detected quantity exceeds available stock",
                        422,
                    )
            else:
                new_quantity = rec.detected_quantity
            delta = new_quantity - current_quantity

            if current is None:
                current = Inventory(
                    tenant_id=tenant_id,
                    store_id=store_id,
                    product_id=rec.product_id,
                    quantity=new_quantity,
                )
                db.add(current)
            else:
                current.quantity = new_quantity
                current.version += 1

            db.add(
                StockMovement(
                    tenant_id=tenant_id,
                    store_id=store_id,
                    product_id=rec.product_id,
                    quantity_delta=delta,
                    resulting_quantity=new_quantity,
                    movement_type=OPERATION_MOVEMENT_TYPE[session.operation],
                    reference_type=REFERENCE_TYPE_SCAN_SESSION,
                    reference_id=str(session_id),
                    notes=OPERATION_MOVEMENT_NOTES[session.operation],
                    created_by=actor_id,
                )
            )
            rec.status = RECONCILIATION_APPLIED
            rec.resolution = RECONCILIATION_RESOLUTION_APPLY
            rec.confirmed_by = actor_id
            rec.confirmed_at = now
            applied.append(
                {
                    "product_id": str(rec.product_id),
                    "system_quantity": str(rec.system_quantity),
                    "detected_quantity": str(rec.detected_quantity),
                    "delta": str(delta),
                }
            )

        session.status = SESSION_STATUS_CONFIRMED
        await write_audit(
            db,
            action="scan_confirmed",
            entity_type="scan_session",
            entity_id=str(session_id),
            tenant_id=tenant_id,
            store_id=store_id,
            user_id=actor_id,
            after={"products": applied},
        )
        await db.commit()
    except IntegrityError as exc:
        await db.rollback()
        raise AppError(CODE_CONFLICT, "Scan has already been confirmed", 409) from exc
    except AppError:
        await db.rollback()
        raise
    except Exception:
        await db.rollback()
        raise
    return session


def _variance_for(operation: str, detected: Decimal, system_quantity: Decimal) -> Decimal:
    """Signed delta a confirmed scan will apply, per operation.

    count replaces the shelf quantity (detected − system); receive adds the
    detected amount (+detected); sale subtracts it (−detected). The same rule
    drives reconciliation build (process) and review override (update).
    """
    if operation == SCAN_OPERATION_RECEIVE:
        return detected
    if operation == SCAN_OPERATION_SALE:
        return -detected
    return detected - system_quantity


def _detection_status(item: DetectedItem, product_id: uuid.UUID | None) -> str:
    """Centralized confidence gate: below the single configured threshold, or an
    unresolvable product, the detection (and therefore the session) is flagged."""
    threshold = Decimal(str(get_settings().ai_confidence_threshold))
    if product_id is None:
        return DETECTION_NEEDS_REVIEW
    if item.method != "manual" and (item.confidence is None or item.confidence < threshold):
        return DETECTION_NEEDS_REVIEW
    return DETECTION_ACCEPTED


async def _resolve_product(
    db: AsyncSession, tenant_id: uuid.UUID, store_id: uuid.UUID, item: DetectedItem
) -> Product | None:
    """Resolve a detection to a product, strictly scoped to (tenant, store).

    Priority: barcode first (more specific), then SKU, then visual/name match.
    Returns None when unresolved — the caller flags the detection for review.
    """
    if item.detected_barcode is not None:
        normalized = normalize_barcode(item.detected_barcode)
        product = (
            await db.execute(
                select(Product).where(
                    Product.tenant_id == tenant_id,
                    Product.store_id == store_id,
                    Product.barcode == normalized,
                )
            )
        ).scalar_one_or_none()
        if product is not None:
            return product

    if item.detected_sku is not None:
        sku = item.detected_sku.strip()
        product = (
            await db.execute(
                select(Product).where(
                    Product.tenant_id == tenant_id,
                    Product.store_id == store_id,
                    Product.sku == sku,
                )
            )
        ).scalar_one_or_none()
        if product is not None:
            return product

    # M4-B: visual/name matching — extract a product name from the vision
    # adapter's metadata and try a case-insensitive substring match within the
    # store.  The vision adapter must never set product_id directly; the
    # service layer always owns identity resolution.
    detected_name = (item.meta or {}).get("name")
    if detected_name:
        product = await _resolve_product_by_name(db, tenant_id, store_id, detected_name)
        if product is not None:
            return product

    return None


async def _resolve_product_by_name(
    db: AsyncSession, tenant_id: uuid.UUID, store_id: uuid.UUID, name: str
) -> Product | None:
    """Best-effort name match within a store, strictly tenant/store-scoped.

    Strategy: exact match first (case-insensitive), then all-products scan
    for the best substring overlap.  Returns None when no confident match
    can be made — the detection is flagged for review by the caller.
    """
    # 1. Exact name match (case-insensitive)
    product = (
        await db.execute(
            select(Product).where(
                Product.tenant_id == tenant_id,
                Product.store_id == store_id,
                Product.name.ilike(name.strip()),
                Product.status == "active",
            )
        )
    ).scalar_one_or_none()
    if product is not None:
        return product

    # 2. Substring overlap — fetch active products in the store and score them.
    #    For a 5–100 product pilot store this is cheap and deterministic.
    products = (
        await db.execute(
            select(Product).where(
                Product.tenant_id == tenant_id,
                Product.store_id == store_id,
                Product.status == "active",
            )
        )
    ).scalars().all()
    if not products:
        return None

    name_lower = name.lower()
    best_product: Product | None = None
    best_score = 0
    for p in products:
        pname = p.name.lower()
        # Score: number of words in the detected name that appear in the product name
        name_words = [w for w in name_lower.split() if len(w) >= 2]
        if not name_words:
            continue
        score = sum(1 for w in name_words if w in pname)
        # Bonus for overall containment
        if name_lower in pname or pname in name_lower:
            score += 2
        if score > best_score:
            best_score = score
            best_product = p

    # Require a minimum overlap — at least 2 matching words or one containment
    if best_score >= 2 and best_product is not None:
        return best_product
    return None


def _aggregate(resolved: list[tuple[uuid.UUID | None, DetectedItem, str]]) -> dict[uuid.UUID, Decimal]:
    """Counted quantities keyed by product. Deterministic: exact Decimal sums,
    keyed aggregation — item order never changes the totals."""
    totals: dict[uuid.UUID, Decimal] = {}
    for product_id, item, _ in resolved:
        if product_id is None:
            continue
        totals[product_id] = totals.get(product_id, Decimal(0)) + item.quantity
    return totals
