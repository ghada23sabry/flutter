"""First-release sprint — scan operations (count / receive / sale).

Proves the three business workflows share one pipeline and confirm path while
writing semantically correct, distinguishable movements:

- count   → replaces shelf quantity, writes COUNT movements (existing M4-A)
- receive → adds the detected quantity, writes PURCHASE movements
- sale    → subtracts the detected quantity, writes SALE movements; never lets
            stock go negative (422 + full rollback)

Covers: operation plumbing + validation, per-operation variance build and
override, correct signed deltas / resulting quantities / movement types,
insufficient-stock rejection with full atomic rollback, no-movement for zero
quantity, inventory-row creation on receive, the DB-level dedup guard for the
new movement types, and HTTP-level operation acceptance.
"""

import uuid
from decimal import Decimal

import pytest
from conftest import cleanup_tenant, make_tenant
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from test_scan_service import (
    BARCODE_A,
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
from app.models import AuditLog, ScanSession, StockMovement
from app.services.ai_service import (
    SCAN_OPERATION_RECEIVE,
    SCAN_OPERATION_SALE,
    SESSION_STATUS_COMPLETED,
    SESSION_STATUS_CONFIRMED,
    confirm_scan_session,
)

MOVEMENT_PURCHASE = "PURCHASE"
MOVEMENT_SALE = "SALE"
REF_SCAN_SESSION = "SCAN_SESSION"


async def _confirm(creds: dict, session_id):
    async with SessionLocal() as db:
        return await confirm_scan_session(
            db,
            tenant_id=creds["tenant_id"],
            store_id=creds["store_id"],
            session_id=session_id,
            actor_id=creds["user_id"],
        )


async def _movements_for(store_id, session_id, movement_type):
    async with SessionLocal() as db:
        rows = (
            await db.execute(
                select(StockMovement)
                .where(
                    StockMovement.store_id == store_id,
                    StockMovement.movement_type == movement_type,
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


# ── Operation plumbing ───────────────────────────────────────────────────────


async def test_operation_defaults_to_count(tenant_creds):
    await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    assert session.operation == "count"


async def test_create_with_receive_and_sale_operations(tenant_creds):
    await _scan_env(tenant_creds)
    receive = await _create(tenant_creds, operation=SCAN_OPERATION_RECEIVE)
    sale = await _create(tenant_creds, operation=SCAN_OPERATION_SALE)
    assert receive.operation == SCAN_OPERATION_RECEIVE
    assert sale.operation == SCAN_OPERATION_SALE


async def test_create_rejects_unknown_operation(tenant_creds):
    await _scan_env(tenant_creds)
    async with SessionLocal() as db:
        from app.services.ai_service import create_scan_session

        with pytest.raises(AppError) as excinfo:
            await create_scan_session(
                db,
                tenant_id=tenant_creds["tenant_id"],
                store_id=tenant_creds["store_id"],
                actor_id=tenant_creds["user_id"],
                operation="refund",
            )
    assert excinfo.value.status_code == 422


async def test_http_create_echoes_operation_and_rejects_unknown(tenant_creds):
    await _scan_env(tenant_creds)
    client, headers = await _authed_client(tenant_creds)
    async with client:
        created = await client.post(
            "/ai/scans",
            params={"store_id": str(tenant_creds["store_id"])},
            headers=headers,
            json={"operation": SCAN_OPERATION_SALE},
        )
        assert created.status_code == 201, created.text
        assert created.json()["operation"] == SCAN_OPERATION_SALE

        invalid = await client.post(
            "/ai/scans",
            params={"store_id": str(tenant_creds["store_id"])},
            headers=headers,
            json={"operation": "refund"},
        )
        assert invalid.status_code == 422, invalid.text


# ── Receive: detected quantity is added ──────────────────────────────────────


async def test_receive_adds_detected_quantity(tenant_creds):
    env = await _scan_env(tenant_creds)  # A and B at opening 10
    session = await _create(tenant_creds, operation=SCAN_OPERATION_RECEIVE)
    processed = await _process(
        tenant_creds,
        session.id,
        FakeVisionPort([_barcode_item(BARCODE_A, 5), _barcode_item(BARCODE_A, 1)]),
    )
    assert processed.status == SESSION_STATUS_COMPLETED

    recs = await _reconciliations(session.id)
    assert len(recs) == 1
    assert recs[0].detected_quantity == Decimal(6)
    assert recs[0].system_quantity == Decimal(10)
    assert recs[0].variance == Decimal(6), "receive variance is the +detected delta"

    confirmed = await _confirm(tenant_creds, session.id)
    assert confirmed.status == SESSION_STATUS_CONFIRMED
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(16)
    assert await _inventory(tenant_creds["store_id"], env["product_b"]) == Decimal(10)

    moves = await _movements_for(tenant_creds["store_id"], session.id, MOVEMENT_PURCHASE)
    assert len(moves) == 1
    assert moves[0].product_id == env["product_a"]
    assert moves[0].quantity_delta == Decimal(6)
    assert moves[0].resulting_quantity == Decimal(16)
    assert moves[0].movement_type == MOVEMENT_PURCHASE
    assert len(await _movements_for(tenant_creds["store_id"], session.id, "COUNT")) == 0


async def test_receive_establishes_stock_when_no_inventory_row(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    async with client:
        created = await client.post(
            "/products",
            params={"store_id": str(tenant_creds["store_id"])},
            headers=headers,
            json=_product_payload(name="New SKU", sku="NEW-SKU", barcode="1111111111111"),
        )
        assert created.status_code == 201, created.text
    product_id = uuid.UUID(created.json()["id"])

    session = await _create(tenant_creds, operation=SCAN_OPERATION_RECEIVE)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item("1111111111111", 4)]))
    assert await _inventory(tenant_creds["store_id"], product_id) is None

    await _confirm(tenant_creds, session.id)
    assert await _inventory(tenant_creds["store_id"], product_id) == Decimal(4)

    moves = await _movements_for(tenant_creds["store_id"], session.id, MOVEMENT_PURCHASE)
    assert len(moves) == 1
    assert moves[0].quantity_delta == Decimal(4)
    assert moves[0].resulting_quantity == Decimal(4)


# ── Sale: detected quantity is subtracted ────────────────────────────────────


async def test_sale_subtracts_detected_quantity(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds, operation=SCAN_OPERATION_SALE)
    processed = await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 3)]))
    assert processed.status == SESSION_STATUS_COMPLETED

    recs = await _reconciliations(session.id)
    assert recs[0].variance == Decimal(-3), "sale variance is the −detected delta"

    confirmed = await _confirm(tenant_creds, session.id)
    assert confirmed.status == SESSION_STATUS_CONFIRMED
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(7)

    moves = await _movements_for(tenant_creds["store_id"], session.id, MOVEMENT_SALE)
    assert len(moves) == 1
    assert moves[0].product_id == env["product_a"]
    assert moves[0].quantity_delta == Decimal(-3)
    assert moves[0].resulting_quantity == Decimal(7)
    assert moves[0].movement_type == MOVEMENT_SALE


async def test_sale_rejects_insufficient_stock_and_rolls_back(tenant_creds):
    env = await _scan_env(tenant_creds)  # A at 10, B at 10
    session = await _create(tenant_creds, operation=SCAN_OPERATION_SALE)
    await _process(
        tenant_creds,
        session.id,
        FakeVisionPort([_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_A, 12)]),  # A total 15 > 10
    )

    with pytest.raises(AppError) as excinfo:
        await _confirm(tenant_creds, session.id)
    assert excinfo.value.status_code == 422
    assert "Insufficient stock" in str(excinfo.value)

    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(10)
    assert await _inventory(tenant_creds["store_id"], env["product_b"]) == Decimal(10)
    assert await _movements_for(tenant_creds["store_id"], session.id, MOVEMENT_SALE) == []
    assert await _audit_rows(session.id) == []
    assert await _session_status(session.id) == SESSION_STATUS_COMPLETED

    recs = await _reconciliations(session.id)
    assert all(r.status == "needs_review" for r in recs)
    assert all(r.confirmed_by is None and r.confirmed_at is None for r in recs)


async def test_sale_rejects_when_no_inventory_row(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    async with client:
        created = await client.post(
            "/products",
            params={"store_id": str(tenant_creds["store_id"])},
            headers=headers,
            json=_product_payload(name="New SKU", sku="NEW-SKU", barcode="1111111111111"),
        )
        assert created.status_code == 201, created.text
    product_id = uuid.UUID(created.json()["id"])

    session = await _create(tenant_creds, operation=SCAN_OPERATION_SALE)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item("1111111111111", 2)]))
    assert await _inventory(tenant_creds["store_id"], product_id) is None

    with pytest.raises(AppError) as excinfo:
        await _confirm(tenant_creds, session.id)
    assert excinfo.value.status_code == 422
    assert await _movements_for(tenant_creds["store_id"], session.id, MOVEMENT_SALE) == []


# ── Zero-quantity rows write no movement (all operations) ────────────────────


async def test_receive_override_to_zero_writes_no_movement(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds, operation=SCAN_OPERATION_RECEIVE)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 5)]))

    async with SessionLocal() as db:
        from app.services.ai_service import update_reconciliation

        rec_id = (await _reconciliations(session.id))[0].id
        await update_reconciliation(
            db,
            tenant_id=tenant_creds["tenant_id"],
            store_id=tenant_creds["store_id"],
            session_id=session.id,
            reconciliation_id=rec_id,
            actor_id=tenant_creds["user_id"],
            resolution="apply",
            detected_quantity=Decimal(0),
        )

    recs = await _reconciliations(session.id)
    assert recs[0].status == "no_change"
    assert recs[0].variance == Decimal(0)

    await _confirm(tenant_creds, session.id)
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(10)
    assert await _movements_for(tenant_creds["store_id"], session.id, MOVEMENT_PURCHASE) == []


async def test_sale_always_produces_negative_delta(tenant_creds):
    await _scan_env(tenant_creds)
    session = await _create(tenant_creds, operation=SCAN_OPERATION_SALE)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 1)]))
    recs = await _reconciliations(session.id)
    assert recs[0].variance == Decimal(-1)
    assert recs[0].status == "needs_review", "a sale always changes stock; no_change is impossible via detections"


# ── Override recomputes the operation-aware variance ─────────────────────────


async def test_receive_override_adds_positive_delta(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds, operation=SCAN_OPERATION_RECEIVE)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 5)]))

    async with SessionLocal() as db:
        from app.services.ai_service import update_reconciliation

        rec_id = (await _reconciliations(session.id))[0].id
        await update_reconciliation(
            db,
            tenant_id=tenant_creds["tenant_id"],
            store_id=tenant_creds["store_id"],
            session_id=session.id,
            reconciliation_id=rec_id,
            actor_id=tenant_creds["user_id"],
            resolution="apply",
            detected_quantity=Decimal(7),
        )
    recs = await _reconciliations(session.id)
    assert recs[0].detected_quantity == Decimal(7)
    assert recs[0].variance == Decimal(7)

    await _confirm(tenant_creds, session.id)
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(17)
    moves = await _movements_for(tenant_creds["store_id"], session.id, MOVEMENT_PURCHASE)
    assert moves[0].quantity_delta == Decimal(7)
    assert moves[0].resulting_quantity == Decimal(17)


async def test_sale_override_subtracts_negative_delta(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds, operation=SCAN_OPERATION_SALE)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 5)]))

    async with SessionLocal() as db:
        from app.services.ai_service import update_reconciliation

        rec_id = (await _reconciliations(session.id))[0].id
        await update_reconciliation(
            db,
            tenant_id=tenant_creds["tenant_id"],
            store_id=tenant_creds["store_id"],
            session_id=session.id,
            reconciliation_id=rec_id,
            actor_id=tenant_creds["user_id"],
            resolution="apply",
            detected_quantity=Decimal(4),
        )
    recs = await _reconciliations(session.id)
    assert recs[0].variance == Decimal(-4)

    await _confirm(tenant_creds, session.id)
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(6)
    moves = await _movements_for(tenant_creds["store_id"], session.id, MOVEMENT_SALE)
    assert moves[0].quantity_delta == Decimal(-4)
    assert moves[0].resulting_quantity == Decimal(6)


async def test_sale_override_to_insufficient_still_rejected(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds, operation=SCAN_OPERATION_SALE)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 3)]))

    async with SessionLocal() as db:
        from app.services.ai_service import update_reconciliation

        rec_id = (await _reconciliations(session.id))[0].id
        await update_reconciliation(
            db,
            tenant_id=tenant_creds["tenant_id"],
            store_id=tenant_creds["store_id"],
            session_id=session.id,
            reconciliation_id=rec_id,
            actor_id=tenant_creds["user_id"],
            resolution="apply",
            detected_quantity=Decimal(20),
        )

    with pytest.raises(AppError) as excinfo:
        await _confirm(tenant_creds, session.id)
    assert excinfo.value.status_code == 422
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(10)
    assert await _movements_for(tenant_creds["store_id"], session.id, MOVEMENT_SALE) == []


# ── Duplicate / DB-level dedup for the new movement types ────────────────────


async def test_receive_double_confirm_rejected(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds, operation=SCAN_OPERATION_RECEIVE)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 5)]))
    await _confirm(tenant_creds, session.id)

    with pytest.raises(AppError) as excinfo:
        await _confirm(tenant_creds, session.id)
    assert excinfo.value.status_code == 409

    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(15)
    assert len(await _movements_for(tenant_creds["store_id"], session.id, MOVEMENT_PURCHASE)) == 1


async def test_db_guard_blocks_duplicate_scan_movement(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds, operation=SCAN_OPERATION_RECEIVE)
    await _process(tenant_creds, session.id, FakeVisionPort([_barcode_item(BARCODE_A, 5)]))
    await _confirm(tenant_creds, session.id)

    async with SessionLocal() as db:
        db.add(
            StockMovement(
                tenant_id=tenant_creds["tenant_id"],
                store_id=tenant_creds["store_id"],
                product_id=env["product_a"],
                quantity_delta=Decimal(5),
                resulting_quantity=Decimal(20),
                movement_type=MOVEMENT_PURCHASE,
                reference_type=REF_SCAN_SESSION,
                reference_id=str(session.id),
                notes="forged duplicate",
                created_by=tenant_creds["user_id"],
            )
        )
        with pytest.raises(IntegrityError):
            await db.flush()


# ── Cross-tenant isolation holds for the new operations ──────────────────────


async def test_receive_cross_tenant_404():
    tenant_a = await make_tenant(f"owner-a-{uuid.uuid4().hex[:8]}@test.dev")
    tenant_b = await make_tenant(f"owner-b-{uuid.uuid4().hex[:8]}@test.dev")
    try:
        env_a = await _scan_env(tenant_a)
        session = await _create(tenant_a, operation=SCAN_OPERATION_RECEIVE)
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
    finally:
        await cleanup_tenant(tenant_a)
        await cleanup_tenant(tenant_b)


# ── HTTP confirmation for sale produces a SALE movement ──────────────────────


async def test_http_sale_confirm_writes_sale_movement(tenant_creds):
    env = await _scan_env(tenant_creds)
    client, headers = await _authed_client(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 2)])
    from app.main import app
    from app.routers.ai import get_vision_port_dependency
    app.dependency_overrides[get_vision_port_dependency] = lambda: port
    try:
        async with client:
            created = await client.post(
                "/ai/scans",
                params={"store_id": str(tenant_creds["store_id"])},
                headers=headers,
                json={"operation": SCAN_OPERATION_SALE},
            )
            assert created.status_code == 201, created.text
            session_id = created.json()["id"]
            from app.ai.mock_vision import MockImagePayload, encode_mock_image

            content = encode_mock_image(MockImagePayload(items=[_barcode_item(BARCODE_A, 2)]))
            processed = await client.post(
                f"/ai/scans/{session_id}/process",
                params={"store_id": str(tenant_creds["store_id"])},
                headers=headers,
                content=content,
            )
            assert processed.status_code == 200, processed.text
            confirmed = await client.post(
                f"/ai/scans/{session_id}/confirm",
                params={"store_id": str(tenant_creds["store_id"])},
                headers=headers,
            )
    finally:
        app.dependency_overrides.pop(get_vision_port_dependency, None)
    assert confirmed.status_code == 200, confirmed.text
    assert confirmed.json()["status"] == "confirmed"
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(8)
    moves = await _movements_for(tenant_creds["store_id"], uuid.UUID(session_id), MOVEMENT_SALE)
    assert len(moves) == 1
    assert moves[0].quantity_delta == Decimal(-2)
