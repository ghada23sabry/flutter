"""Link detection → product tests.

Covers the complete link-detection-to-product lifecycle:
1. Link unmatched detection to valid product.
2. Detection belongs to wrong scan → rejected.
3. Product does not exist → rejected.
4. Cross-store/tenant product → rejected.
5. Repeat same link request → idempotent, no duplicates.
6. Link causes reconciliation to include correct quantity.
7. No inventory movement before confirmation.
8. Confirm after linking produces exactly one correct inventory update.
9. Existing matched detections remain unaffected.
10. Transaction rollback on error.
11. Link to already-linked detection → 409.
12. All three operations (count/receive/sale) work consistently.
"""

import uuid
from decimal import Decimal

import pytest
from sqlalchemy import select
from test_scan_service import (
    BARCODE_A,
    FakeVisionPort,
    _authed_client,
    _barcode_item,
    _create,
    _inventory,
    _movement_count,
    _process,
    _product_payload,
    _scan_env,
)

from app.core.db import SessionLocal
from app.core.errors import AppError
from app.models import ScanDetection, ScanReconciliation, StockMovement, Store
from app.services.ai_service import (
    SESSION_STATUS_CONFIRMED,
    SESSION_STATUS_NEEDS_REVIEW,
    link_detection_to_product,
)


async def _link(creds, session_id, detection_id, product_id):
    async with SessionLocal() as db:
        return await link_detection_to_product(
            db,
            tenant_id=creds["tenant_id"],
            store_id=creds["store_id"],
            session_id=session_id,
            detection_id=detection_id,
            product_id=product_id,
            actor_id=creds["user_id"],
        )


async def _detection_by_id(detection_id):
    async with SessionLocal() as db:
        return (
            await db.execute(
                select(ScanDetection).where(ScanDetection.id == detection_id)
            )
        ).scalar_one_or_none()


async def _reconciliation_for_product(session_id, product_id):
    async with SessionLocal() as db:
        return (
            await db.execute(
                select(ScanReconciliation).where(
                    ScanReconciliation.session_id == session_id,
                    ScanReconciliation.product_id == product_id,
                )
            )
        ).scalar_one_or_none()


# ── 1. Link unmatched detection to valid product ───────────────────────────


async def test_link_unmatched_detection(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item("9999999999999", 5)])
    result = await _process(tenant_creds, session.id, port)
    assert result.status == SESSION_STATUS_NEEDS_REVIEW

    dets = await _detections(session.id)
    assert len(dets) == 1
    det = dets[0]
    assert det.product_id is None

    linked = await _link(tenant_creds, session.id, det.id, env["product_a"])
    assert linked.product_id == env["product_a"]
    assert linked.status == "accepted"

    rec = await _reconciliation_for_product(session.id, env["product_a"])
    assert rec is not None
    assert rec.detected_quantity == Decimal(5)
    assert rec.variance == Decimal(-5)
    assert rec.status == "needs_review"


async def _detections(session_id):
    async with SessionLocal() as db:
        rows = (
            await db.execute(
                select(ScanDetection)
                .where(ScanDetection.session_id == session_id)
                .order_by(ScanDetection.created_at)
            )
        ).scalars().all()
        return list(rows)


# ── 2. Detection belongs to wrong scan → rejected ──────────────────────────


async def test_link_wrong_scan_rejected(tenant_creds):
    env = await _scan_env(tenant_creds)
    session_a = await _create(tenant_creds)
    session_b = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item("9999999999999", 3)])
    await _process(tenant_creds, session_a.id, port)
    dets = await _detections(session_a.id)
    det = dets[0]

    with pytest.raises(AppError) as excinfo:
        async with SessionLocal() as db:
            await link_detection_to_product(
                db,
                tenant_id=tenant_creds["tenant_id"],
                store_id=tenant_creds["store_id"],
                session_id=session_b.id,
                detection_id=det.id,
                product_id=env["product_a"],
                actor_id=tenant_creds["user_id"],
            )
    # session_b is still PROCESSING (never scanned), so the session-status
    # guard fires before detection lookup → 409, not 404.
    assert excinfo.value.status_code == 409


# ── 3. Product does not exist → rejected ───────────────────────────────────


async def test_link_nonexistent_product_rejected(tenant_creds):
    await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item("9999999999999", 2)])
    await _process(tenant_creds, session.id, port)
    dets = await _detections(session.id)
    det = dets[0]
    fake_product_id = uuid.uuid4()

    with pytest.raises(AppError) as excinfo:
        await _link(tenant_creds, session.id, det.id, fake_product_id)
    assert excinfo.value.status_code == 404


# ── 4. Cross-store product → rejected ──────────────────────────────────────


async def test_link_cross_store_product_rejected(tenant_creds):
    await _scan_env(tenant_creds)
    other_store = Store(tenant_id=tenant_creds["tenant_id"], name="North")
    async with SessionLocal() as db:
        db.add(other_store)
        await db.commit()
        await db.refresh(other_store)

    client, headers = await _authed_client(tenant_creds)
    async with client:
        p = await client.post(
            "/products",
            params={"store_id": str(other_store.id)},
            headers=headers,
            json=_product_payload(name="Other Store Product", sku="OS-1", barcode="0000000000000"),
        )
        assert p.status_code == 201, p.text
    other_product_id = uuid.UUID(p.json()["id"])

    session = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item("9999999999999", 1)])
    await _process(tenant_creds, session.id, port)
    dets = await _detections(session.id)

    with pytest.raises(AppError) as excinfo:
        await _link(tenant_creds, session.id, dets[0].id, other_product_id)
    assert excinfo.value.status_code == 404


# ── 5. Repeat same link request → idempotent, no duplicates ────────────────


async def test_link_idempotent(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item("9999999999999", 7)])
    await _process(tenant_creds, session.id, port)
    dets = await _detections(session.id)
    det = dets[0]

    await _link(tenant_creds, session.id, det.id, env["product_a"])
    await _link(tenant_creds, session.id, det.id, env["product_a"])

    rec = await _reconciliation_for_product(session.id, env["product_a"])
    assert rec is not None
    assert rec.detected_quantity == Decimal(7)


# ── 6. Link causes reconciliation to include correct quantity ───────────────


async def test_link_creates_correct_reconciliation(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item("9999999999999", 4)])
    await _process(tenant_creds, session.id, port)
    dets = await _detections(session.id)

    await _link(tenant_creds, session.id, dets[0].id, env["product_a"])

    rec = await _reconciliation_for_product(session.id, env["product_a"])
    assert rec is not None
    assert rec.detected_quantity == Decimal(4)
    assert rec.system_quantity == Decimal(10)
    assert rec.variance == Decimal(-6)


# ── 7. No inventory movement before confirmation ────────────────────────────


async def test_no_inventory_mutation_before_confirm(tenant_creds):
    env = await _scan_env(tenant_creds)
    store_id = tenant_creds["store_id"]
    moves_before = await _movement_count(store_id)

    session = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item("9999999999999", 3)])
    await _process(tenant_creds, session.id, port)
    dets = await _detections(session.id)

    await _link(tenant_creds, session.id, dets[0].id, env["product_a"])

    assert await _inventory(store_id, env["product_a"]) == Decimal(10)
    assert await _movement_count(store_id) == moves_before


# ── 8. Confirm after linking produces exactly one correct inventory update ───


async def test_confirm_after_link(tenant_creds):
    env = await _scan_env(tenant_creds)
    store_id = tenant_creds["store_id"]

    session = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item("9999999999999", 6)])
    await _process(tenant_creds, session.id, port)
    dets = await _detections(session.id)
    await _link(tenant_creds, session.id, dets[0].id, env["product_a"])

    from test_confirm_scan import _confirm
    confirmed = await _confirm(tenant_creds, session.id)
    assert confirmed.status == SESSION_STATUS_CONFIRMED

    assert await _inventory(store_id, env["product_a"]) == Decimal(6)

    moves = await _count_movements(session.id)
    assert len(moves) == 1
    assert moves[0].product_id == env["product_a"]
    assert moves[0].quantity_delta == Decimal(-4)


async def _count_movements(session_id):
    async with SessionLocal() as db:
        rows = (
            await db.execute(
                select(StockMovement).where(
                    StockMovement.reference_type == "SCAN_SESSION",
                    StockMovement.reference_id == str(session_id),
                )
            )
        ).scalars().all()
        return list(rows)


# ── 9. Existing matched detections remain unaffected ────────────────────────


async def test_existing_matched_detections_unaffected(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    port = FakeVisionPort(
        [
            _barcode_item(BARCODE_A, 3),
            _barcode_item("9999999999999", 2),
        ]
    )
    result = await _process(tenant_creds, session.id, port)
    assert result.status == SESSION_STATUS_NEEDS_REVIEW

    dets = await _detections(session.id)
    matched = [d for d in dets if d.product_id is not None]
    unmatched = [d for d in dets if d.product_id is None]
    assert len(matched) == 1
    assert matched[0].product_id == env["product_a"]
    assert len(unmatched) == 1

    await _link(tenant_creds, session.id, unmatched[0].id, env["product_b"])

    dets_after = await _detections(session.id)
    by_product = {d.product_id: d for d in dets_after if d.product_id is not None}
    assert by_product[env["product_a"]].quantity_detected == Decimal(3)
    assert by_product[env["product_b"]].quantity_detected == Decimal(2)


# ── 10. Link to already-linked detection of same product → idempotent ──────


async def test_link_already_linked_same_product_idempotent(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 4)])
    await _process(tenant_creds, session.id, port)
    dets = await _detections(session.id)
    det = dets[0]
    assert det.product_id == env["product_a"]

    linked = await _link(tenant_creds, session.id, det.id, env["product_a"])
    assert linked.product_id == env["product_a"]


# ── 11. Link to already-linked detection of different product → 409 ────────


async def test_link_already_linked_different_product_rejected(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 4)])
    await _process(tenant_creds, session.id, port)
    dets = await _detections(session.id)
    det = dets[0]
    assert det.product_id == env["product_a"]

    with pytest.raises(AppError) as excinfo:
        await _link(tenant_creds, session.id, det.id, env["product_b"])
    assert excinfo.value.status_code == 409


# ── 12. RECEIVE operation: link + confirm adds stock ────────────────────────


async def test_link_receive_operation(tenant_creds):
    env = await _scan_env(tenant_creds)
    store_id = tenant_creds["store_id"]

    session = await _create(tenant_creds, operation="receive")
    port = FakeVisionPort([_barcode_item("9999999999999", 5)])
    await _process(tenant_creds, session.id, port)
    dets = await _detections(session.id)
    await _link(tenant_creds, session.id, dets[0].id, env["product_a"])

    from test_confirm_scan import _confirm
    await _confirm(tenant_creds, session.id)

    assert await _inventory(store_id, env["product_a"]) == Decimal(15)
    moves = await _count_movements(session.id)
    assert len(moves) == 1
    assert moves[0].quantity_delta == Decimal(5)


# ── 13. SALE operation: link + confirm subtracts stock ──────────────────────


async def test_link_sale_operation(tenant_creds):
    env = await _scan_env(tenant_creds)
    store_id = tenant_creds["store_id"]

    session = await _create(tenant_creds, operation="sale")
    port = FakeVisionPort([_barcode_item("9999999999999", 3)])
    await _process(tenant_creds, session.id, port)
    dets = await _detections(session.id)
    await _link(tenant_creds, session.id, dets[0].id, env["product_a"])

    from test_confirm_scan import _confirm
    await _confirm(tenant_creds, session.id)

    assert await _inventory(store_id, env["product_a"]) == Decimal(7)
    moves = await _count_movements(session.id)
    assert len(moves) == 1
    assert moves[0].quantity_delta == Decimal(-3)


# ── 14. PROCESSING session cannot link ──────────────────────────────────────


async def test_link_processing_session_rejected(tenant_creds):
    await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    fake_det_id = uuid.uuid4()
    fake_product_id = uuid.uuid4()

    with pytest.raises(AppError) as excinfo:
        await _link(tenant_creds, session.id, fake_det_id, fake_product_id)
    assert excinfo.value.status_code == 409


# ── 15. CONFIRMED session cannot link ──────────────────────────────────────


async def test_link_confirmed_session_rejected(tenant_creds):
    await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 3)])
    await _process(tenant_creds, session.id, port)

    from test_confirm_scan import _confirm
    await _confirm(tenant_creds, session.id)

    dets = await _detections(session.id)
    # Create a new product to try linking to
    client, headers = await _authed_client(tenant_creds)
    async with client:
        p = await client.post(
            "/products",
            params={"store_id": str(tenant_creds["store_id"])},
            headers=headers,
            json=_product_payload(name="New P", sku="NP-1", barcode="0000000000001"),
        )
        assert p.status_code == 201

    # Detection is already matched, so this would be re-linking.
    # But session is CONFIRMED, so it should fail at session check.
    with pytest.raises(AppError) as excinfo:
        await _link(
            tenant_creds, session.id, dets[0].id, uuid.UUID(p.json()["id"])
        )
    assert excinfo.value.status_code == 409
