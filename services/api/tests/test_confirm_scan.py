"""M4-A.4 — explicit scan confirmation applies counts as COUNT movements.

Covers the required confirmation contract:
successful confirmation, correct signed inventory delta, exactly one COUNT
movement per affected product, audit row, complete rollback on failure,
duplicate / concurrent double-apply protection, stale inventory rejection,
FAILED/CANCELLED non-confirmable, cross-tenant/store 404, NEEDS_REVIEW requiring
explicit confirmation, no duplicate movement.
"""

import asyncio
import uuid
from decimal import Decimal

import pytest
from conftest import cleanup_tenant, make_tenant
from sqlalchemy import func, select
from test_scan_service import (
    BARCODE_A,
    BARCODE_B,
    FakeVisionPort,
    _authed_client,
    _barcode_item,
    _create,
    _inventory,
    _process,
    _product_payload,
    _reconciliations,
    _scan_env,
)

from app.core.db import SessionLocal
from app.core.errors import AppError
from app.models import AuditLog, Inventory, ScanSession, StockMovement, Store
from app.services.ai_service import (
    SESSION_STATUS_CANCELLED,
    SESSION_STATUS_COMPLETED,
    SESSION_STATUS_CONFIRMED,
    SESSION_STATUS_NEEDS_REVIEW,
    confirm_scan_session,
)

MOVEMENT_COUNT = "COUNT"
REF_SCAN_SESSION = "SCAN_SESSION"


async def _confirm(creds: dict, session_id, *, actor_id=None):
    async with SessionLocal() as db:
        result = await confirm_scan_session(
            db,
            tenant_id=creds["tenant_id"],
            store_id=creds["store_id"],
            session_id=session_id,
            actor_id=actor_id or creds["user_id"],
        )
        return result.session


async def _count_movements(store_id, session_id):
    async with SessionLocal() as db:
        rows = (
            await db.execute(
                select(StockMovement)
                .where(
                    StockMovement.store_id == store_id,
                    StockMovement.movement_type == MOVEMENT_COUNT,
                    StockMovement.reference_type == REF_SCAN_SESSION,
                    StockMovement.reference_id == str(session_id),
                )
                .order_by(StockMovement.product_id)
            )
        ).scalars().all()
        return list(rows)


async def _audit_rows(session_id):
    async with SessionLocal() as db:
        rows = (
            await db.execute(
                select(AuditLog).where(AuditLog.action == "scan_confirmed", AuditLog.entity_id == str(session_id))
            )
        ).scalars().all()
        return list(rows)


async def _session_status(session_id) -> str:
    async with SessionLocal() as db:
        return (await db.execute(select(ScanSession.status).where(ScanSession.id == session_id))).scalar_one()


# ── 1. Successful confirmation ──────────────────────────────────────────────


async def test_confirm_success(tenant_creds):
    env = await _scan_env(tenant_creds)  # A and B each at opening 10
    session = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_B, 2)])
    processed = await _process(tenant_creds, session.id, port)
    assert processed.status == SESSION_STATUS_COMPLETED

    confirmed = await _confirm(tenant_creds, session.id)
    assert confirmed.status == SESSION_STATUS_CONFIRMED

    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(3)
    assert await _inventory(tenant_creds["store_id"], env["product_b"]) == Decimal(2)

    recs = await _reconciliations(session.id)
    assert {r.status for r in recs} == {"applied"}
    assert {r.resolution for r in recs} == {"apply"}
    assert all(r.confirmed_by == tenant_creds["user_id"] for r in recs)
    assert all(r.confirmed_at is not None for r in recs)


# ── 2. Correct inventory delta ──────────────────────────────────────────────


async def test_confirm_applies_correct_delta(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    await _process(
        tenant_creds,
        session.id,
        FakeVisionPort([_barcode_item(BARCODE_A, 6), _barcode_item(BARCODE_B, 13)]),
    )
    await _confirm(tenant_creds, session.id)

    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(6)
    assert await _inventory(tenant_creds["store_id"], env["product_b"]) == Decimal(13)

    by_product = {m.product_id: m for m in await _count_movements(tenant_creds["store_id"], session.id)}
    assert by_product[env["product_a"]].quantity_delta == Decimal(-4)
    assert by_product[env["product_a"]].resulting_quantity == Decimal(6)
    assert by_product[env["product_b"]].quantity_delta == Decimal(3)
    assert by_product[env["product_b"]].resulting_quantity == Decimal(13)


# ── 3. Exactly one COUNT movement per affected product ──────────────────────


async def test_exactly_one_count_movement_per_affected_product(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 4), _barcode_item(BARCODE_B, 9)]))
    await _confirm(tenant_creds, session.id)

    moves = await _count_movements(tenant_creds["store_id"], session.id)
    assert len(moves) == 2
    assert {m.product_id for m in moves} == {env["product_a"], env["product_b"]}

    async with SessionLocal() as db:
        counts = (
            await db.execute(
                select(StockMovement.product_id, func.count())
                .where(
                    StockMovement.store_id == tenant_creds["store_id"],
                    StockMovement.movement_type == MOVEMENT_COUNT,
                    StockMovement.reference_type == REF_SCAN_SESSION,
                    StockMovement.reference_id == str(session.id),
                )
                .group_by(StockMovement.product_id)
            )
        ).all()
        assert {pid: c for pid, c in counts} == {env["product_a"]: 1, env["product_b"]: 1}


# ── 4. Audit created ────────────────────────────────────────────────────────


async def test_confirm_creates_audit(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 2)]))
    await _confirm(tenant_creds, session.id)

    rows = await _audit_rows(session.id)
    assert len(rows) == 1
    assert rows[0].action == "scan_confirmed"
    assert rows[0].entity_type == "scan_session"
    assert rows[0].entity_id == str(session.id)
    assert rows[0].tenant_id == tenant_creds["tenant_id"]
    assert rows[0].store_id == tenant_creds["store_id"]
    assert rows[0].user_id == tenant_creds["user_id"]
    assert rows[0].after is not None
    assert env is not None


# ── 5. Complete transaction rollback on failure ─────────────────────────────


async def test_confirm_rolls_back_everything_on_failure(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    await _process(
        tenant_creds,
        session.id,
        FakeVisionPort([_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_B, 2)]),
    )

    # External change to B only → B is stale; A's count must NOT be applied.
    client, headers = await _authed_client(tenant_creds)
    async with client:
        adjusted = await client.patch(
            f"/inventory/stock/{env['product_b']}",
            params={"store_id": str(tenant_creds["store_id"])},
            headers=headers,
            json={"new_quantity": "7", "reason": "manual recount before confirm"},
        )
        assert adjusted.status_code == 200, adjusted.text

    with pytest.raises(AppError) as excinfo:
        await _confirm(tenant_creds, session.id)
    assert excinfo.value.status_code == 409

    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(10)
    assert await _inventory(tenant_creds["store_id"], env["product_b"]) == Decimal(7)
    assert await _count_movements(tenant_creds["store_id"], session.id) == []
    assert await _audit_rows(session.id) == []
    assert await _session_status(session.id) == SESSION_STATUS_COMPLETED

    recs = await _reconciliations(session.id)
    assert all(r.status == "needs_review" for r in recs)
    assert all(r.confirmed_by is None and r.confirmed_at is None for r in recs)


# ── 6. Duplicate confirmation rejected ──────────────────────────────────────


async def test_duplicate_confirmation_rejected(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 4)]))
    await _confirm(tenant_creds, session.id)

    with pytest.raises(AppError) as excinfo:
        await _confirm(tenant_creds, session.id)
    assert excinfo.value.status_code == 409

    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(4)
    assert len(await _count_movements(tenant_creds["store_id"], session.id)) == 1


# ── 7. Concurrent confirmation cannot double-apply ──────────────────────────


async def test_concurrent_confirmation_no_double_apply(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    await _process(
        tenant_creds,
        session.id,
        FakeVisionPort([_barcode_item(BARCODE_A, 5), _barcode_item(BARCODE_B, 6)]),
    )

    async def _try_confirm() -> int:
        async with SessionLocal() as db:
            try:
                await confirm_scan_session(
                    db,
                    tenant_id=tenant_creds["tenant_id"],
                    store_id=tenant_creds["store_id"],
                    session_id=session.id,
                    actor_id=tenant_creds["user_id"],
                )
                return 200
            except AppError as exc:
                return exc.status_code

    results = await asyncio.gather(_try_confirm(), _try_confirm())
    assert sorted(results) == [200, 409]

    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(5)
    assert await _inventory(tenant_creds["store_id"], env["product_b"]) == Decimal(6)
    assert len(await _count_movements(tenant_creds["store_id"], session.id)) == 2

    async with SessionLocal() as db:
        for pid in (env["product_a"], env["product_b"]):
            inv = (
                await db.execute(
                    select(Inventory).where(Inventory.store_id == tenant_creds["store_id"], Inventory.product_id == pid)
                )
            ).scalar_one()
            assert inv.version == 1, "exactly one confirmation must bump the optimistic version guard"


# ── 8. Stale inventory rejected safely ──────────────────────────────────────


async def test_stale_inventory_rejected_safely(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 3)]))

    client, headers = await _authed_client(tenant_creds)
    async with client:
        adjusted = await client.patch(
            f"/inventory/stock/{env['product_a']}",
            params={"store_id": str(tenant_creds["store_id"])},
            headers=headers,
            json={"new_quantity": "7", "reason": "sale before confirm"},
        )
        assert adjusted.status_code == 200, adjusted.text

    with pytest.raises(AppError) as excinfo:
        await _confirm(tenant_creds, session.id)
    assert excinfo.value.status_code == 409

    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(7)
    assert await _count_movements(tenant_creds["store_id"], session.id) == []
    assert await _audit_rows(session.id) == []


# ── 9. FAILED scan cannot confirm ───────────────────────────────────────────


async def test_failed_scan_cannot_confirm(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    with pytest.raises(AppError) as excinfo_process:
        await _process(tenant_creds, session.id, FakeVisionPort(raise_error=True))
    assert excinfo_process.value.status_code == 500

    with pytest.raises(AppError) as excinfo:
        await _confirm(tenant_creds, session.id)
    assert excinfo.value.status_code == 409

    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(10)
    assert await _count_movements(tenant_creds["store_id"], session.id) == []


# ── 10. CANCELLED scan cannot confirm ───────────────────────────────────────


async def test_cancelled_scan_cannot_confirm(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    async with SessionLocal() as db:
        row = (await db.execute(select(ScanSession).where(ScanSession.id == session.id))).scalar_one()
        row.status = SESSION_STATUS_CANCELLED
        await db.commit()

    with pytest.raises(AppError) as excinfo:
        await _confirm(tenant_creds, session.id)
    assert excinfo.value.status_code == 409
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(10)
    assert await _count_movements(tenant_creds["store_id"], session.id) == []


# ── 11. Cross-tenant confirmation → 404 ─────────────────────────────────────


async def test_confirm_cross_tenant_404():
    tenant_a = await make_tenant(f"owner-a-{uuid.uuid4().hex[:8]}@test.dev")
    tenant_b = await make_tenant(f"owner-b-{uuid.uuid4().hex[:8]}@test.dev")
    try:
        env_a = await _scan_env(tenant_a)
        session = await _create(tenant_a)
        await _process(tenant_a, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 3)]))

        async with SessionLocal() as db:
            with pytest.raises(AppError) as excinfo:
                await confirm_scan_session(
                    db,
                    tenant_id=tenant_b["tenant_id"],
                    store_id=tenant_a["store_id"],
                    session_id=session.id,
                    actor_id=tenant_b["user_id"],
                )
        assert excinfo.value.status_code == 404
        assert await _inventory(tenant_a["store_id"], env_a["product_a"]) == Decimal(10)
        assert await _count_movements(tenant_a["store_id"], session.id) == []
    finally:
        await cleanup_tenant(tenant_a)
        await cleanup_tenant(tenant_b)


# ── 12. Cross-store confirmation → 404 ──────────────────────────────────────


async def test_confirm_cross_store_404(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 3)]))

    other_store = Store(tenant_id=tenant_creds["tenant_id"], name="North")
    async with SessionLocal() as db:
        db.add(other_store)
        await db.commit()
        await db.refresh(other_store)
        other_store_id = other_store.id

    async with SessionLocal() as db:
        with pytest.raises(AppError) as excinfo:
            await confirm_scan_session(
                db,
                tenant_id=tenant_creds["tenant_id"],
                store_id=other_store_id,
                session_id=session.id,
                actor_id=tenant_creds["user_id"],
            )
    assert excinfo.value.status_code == 404
    assert await _count_movements(tenant_creds["store_id"], session.id) == []
    assert env is not None


# ── 13. NEEDS_REVIEW still requires explicit confirmation ───────────────────


async def test_needs_review_requires_explicit_confirmation(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    await _process(
        tenant_creds,
        session.id,
        FakeVisionPort(
            [
                _barcode_item(BARCODE_A, 3, confidence=Decimal("0.95")),
                _barcode_item(BARCODE_B, 1, confidence=Decimal("0.50")),
            ]
        ),
    )
    assert await _session_status(session.id) == SESSION_STATUS_NEEDS_REVIEW

    # Nothing applied without the explicit confirm call.
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(10)
    assert await _inventory(tenant_creds["store_id"], env["product_b"]) == Decimal(10)
    assert await _count_movements(tenant_creds["store_id"], session.id) == []
    assert await _audit_rows(session.id) == []

    confirmed = await _confirm(tenant_creds, session.id)
    assert confirmed.status == SESSION_STATUS_CONFIRMED
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(3)
    assert await _inventory(tenant_creds["store_id"], env["product_b"]) == Decimal(1)
    assert len(await _count_movements(tenant_creds["store_id"], session.id)) == 2


# ── 14. No duplicate movement ───────────────────────────────────────────────


async def test_no_duplicate_movement(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 4)]))
    await _confirm(tenant_creds, session.id)
    assert len(await _count_movements(tenant_creds["store_id"], session.id)) == 1

    with pytest.raises(AppError) as excinfo:
        await _confirm(tenant_creds, session.id)
    assert excinfo.value.status_code == 409

    moves = await _count_movements(tenant_creds["store_id"], session.id)
    assert len(moves) == 1
    assert moves[0].product_id == env["product_a"]
    assert moves[0].quantity_delta == Decimal(-6)


# ── Extra state coverage (beyond the required list) ─────────────────────────


async def test_processing_scan_cannot_confirm(tenant_creds):
    await _scan_env(tenant_creds)
    session = await _create(tenant_creds)  # still PROCESSING, no detections yet
    with pytest.raises(AppError) as excinfo:
        await _confirm(tenant_creds, session.id)
    assert excinfo.value.status_code == 409


async def test_zero_variance_marks_applied_without_movement(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 10)]))

    recs_before = await _reconciliations(session.id)
    assert recs_before[0].status == "no_change"
    assert recs_before[0].variance == Decimal(0)

    confirmed = await _confirm(tenant_creds, session.id)
    assert confirmed.status == SESSION_STATUS_CONFIRMED
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(10)
    assert await _count_movements(tenant_creds["store_id"], session.id) == []

    recs = await _reconciliations(session.id)
    assert recs[0].status == "applied"
    assert recs[0].resolution == "apply"


async def test_confirm_establishes_stock_when_no_inventory_row(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        created = await client.post(
            "/products",
            params={"store_id": store_id},
            headers=headers,
            json=_product_payload(name="New SKU", sku="NEW-SKU", barcode="1111111111111"),
        )
        assert created.status_code == 201, created.text
    product_id = uuid.UUID(created.json()["id"])

    session = await _create(tenant_creds)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item("1111111111111", 4)]))
    assert await _inventory(tenant_creds["store_id"], product_id) is None

    confirmed = await _confirm(tenant_creds, session.id)
    assert confirmed.status == SESSION_STATUS_CONFIRMED
    assert await _inventory(tenant_creds["store_id"], product_id) == Decimal(4)

    moves = await _count_movements(tenant_creds["store_id"], session.id)
    assert len(moves) == 1
    assert moves[0].product_id == product_id
    assert moves[0].quantity_delta == Decimal(4)
    assert moves[0].resulting_quantity == Decimal(4)
