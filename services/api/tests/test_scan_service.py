import uuid
from decimal import Decimal

import pytest
from conftest import api_client, cleanup_tenant, login, make_tenant
from sqlalchemy import func, select

from app.ai.contract import DetectedItem
from app.ai.vision_port import AIVisionPort
from app.config import get_settings
from app.core.db import SessionLocal
from app.core.errors import AppError
from app.models import Inventory, ScanDetection, ScanReconciliation, ScanSession, StockMovement, Store
from app.services.ai_service import (
    SESSION_STATUS_COMPLETED,
    SESSION_STATUS_FAILED,
    SESSION_STATUS_NEEDS_REVIEW,
    SESSION_STATUS_PROCESSING,
    create_scan_session,
    process_scan,
)

BARCODE_A = "5901234123457"
SKU_A = "MILK-1L"
BARCODE_B = "6901234567890"
SKU_B = "BREAD-1"


class FakeVisionPort:
    """Scriptable protocol implementation — proves the service only needs AIVisionPort."""

    def __init__(self, items=None, *, raise_error=False):
        self.items = list(items or [])
        self.raise_error = raise_error
        self.calls = 0
        self.last_context = None

    async def analyze_image(self, image: bytes, context):
        self.calls += 1
        self.last_context = context
        if self.raise_error:
            raise RuntimeError("vision backend unavailable")
        return list(self.items)


async def _authed_client(creds: dict):
    login_resp = await login(creds)
    assert login_resp.status_code == 200
    token = login_resp.json()["access_token"]
    return await api_client(), {"Authorization": f"Bearer {token}"}


def _product_payload(**overrides):
    payload = {
        "name": "Milk 1L",
        "sku": SKU_A,
        "barcode": BARCODE_A,
        "unit": "pcs",
        "cost_price": "2.10",
        "selling_price": "3.50",
        "reorder_point": "5",
        "reorder_quantity": "20",
    }
    payload.update(overrides)
    return payload


async def _scan_env(creds):
    """Products A+B (each with opening stock 10) + one shelf in the tenant's store."""
    client, headers = await _authed_client(creds)
    store_id = str(creds["store_id"])
    async with client:
        p_a = await client.post(
            "/products",
            params={"store_id": store_id},
            headers=headers,
            json=_product_payload(name="Milk 1L", sku=SKU_A, barcode=BARCODE_A),
        )
        assert p_a.status_code == 201, p_a.text
        p_b = await client.post(
            "/products",
            params={"store_id": store_id},
            headers=headers,
            json=_product_payload(name="Bread", sku=SKU_B, barcode=BARCODE_B),
        )
        assert p_b.status_code == 201, p_b.text
        for pid in (p_a.json()["id"], p_b.json()["id"]):
            opening = await client.post(
                f"/inventory/stock/{pid}/opening",
                params={"store_id": store_id},
                headers=headers,
                json={"quantity": "10"},
            )
            assert opening.status_code == 201, opening.text
        zone = await client.post("/inventory/zones", params={"store_id": store_id}, headers=headers, json={"name": "AI Zone"})
        assert zone.status_code == 201, zone.text
        shelf = await client.post(
            "/inventory/shelves",
            params={"store_id": store_id},
            headers=headers,
            json={"zone_id": zone.json()["id"], "label": "AI Shelf"},
        )
        assert shelf.status_code == 201, shelf.text
    return {
        "product_a": uuid.UUID(p_a.json()["id"]),
        "product_b": uuid.UUID(p_b.json()["id"]),
        "shelf_id": uuid.UUID(shelf.json()["id"]),
    }


def _barcode_item(code: str, quantity: str | int, confidence: str | Decimal = "0.95") -> DetectedItem:
    return DetectedItem(method="barcode", detected_barcode=code, confidence=Decimal(str(confidence)), quantity=Decimal(str(quantity)))


async def _create(creds, **kwargs):
    async with SessionLocal() as db:
        return await create_scan_session(db, tenant_id=creds["tenant_id"], store_id=creds["store_id"], **kwargs)


async def _process(creds, session_id, port, **kwargs):
    async with SessionLocal() as db:
        return await process_scan(
            db,
            tenant_id=creds["tenant_id"],
            store_id=creds["store_id"],
            session_id=session_id,
            actor_id=creds["user_id"],
            image=b"mock-image-bytes",
            vision_port=port,
            **kwargs,
        )


async def _detections(session_id):
    async with SessionLocal() as db:
        rows = (
            await db.execute(select(ScanDetection).where(ScanDetection.session_id == session_id).order_by(ScanDetection.created_at))
        ).scalars().all()
        return list(rows)


async def _reconciliations(session_id):
    async with SessionLocal() as db:
        rows = (
            await db.execute(
                select(ScanReconciliation).where(ScanReconciliation.session_id == session_id).order_by(ScanReconciliation.product_id)
            )
        ).scalars().all()
        return list(rows)


async def _inventory(store_id, product_id):
    async with SessionLocal() as db:
        row = (
            await db.execute(select(Inventory).where(Inventory.store_id == store_id, Inventory.product_id == product_id))
        ).scalar_one_or_none()
        return row.quantity if row is not None else None


async def _movement_count(store_id):
    async with SessionLocal() as db:
        return (
            await db.execute(select(func.count()).select_from(StockMovement).where(StockMovement.store_id == store_id))
        ).scalar_one()


# ── 1. Successful scan lifecycle ────────────────────────────────────────────


async def test_successful_scan_lifecycle(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds, shelf_id=env["shelf_id"], note="morning count")
    assert session.status == SESSION_STATUS_PROCESSING
    assert session.shelf_id == env["shelf_id"]

    port = FakeVisionPort(
        [
            _barcode_item(BARCODE_A, 3),
            _barcode_item(BARCODE_B, 2),
        ]
    )
    result = await _process(tenant_creds, session.id, port)

    assert result.status == SESSION_STATUS_COMPLETED
    assert port.calls == 1
    assert port.last_context.tenant_id == tenant_creds["tenant_id"]
    assert port.last_context.store_id == tenant_creds["store_id"]
    assert port.last_context.shelf_id == env["shelf_id"]

    dets = await _detections(session.id)
    assert len(dets) == 2
    assert {d.product_id for d in dets} == {env["product_a"], env["product_b"]}
    assert {d.status for d in dets} == {"accepted"}

    recs = await _reconciliations(session.id)
    assert len(recs) == 2
    by_product = {r.product_id: r for r in recs}
    assert by_product[env["product_a"]].detected_quantity == Decimal(3)
    assert by_product[env["product_a"]].system_quantity == Decimal(10)
    assert by_product[env["product_a"]].variance == Decimal(-7)
    assert by_product[env["product_b"]].variance == Decimal(-8)
    assert by_product[env["product_a"]].status == "needs_review"


# ── 2. Tenant isolation ─────────────────────────────────────────────────────


async def test_scan_tenant_isolation():
    tenant_a = await make_tenant(f"owner-a-{uuid.uuid4().hex[:8]}@test.dev")
    tenant_b = await make_tenant(f"owner-b-{uuid.uuid4().hex[:8]}@test.dev")
    try:
        env_a = await _scan_env(tenant_a)
        session_a = await _create(tenant_a, shelf_id=env_a["shelf_id"])
        port = FakeVisionPort([_barcode_item(BARCODE_A, 1)])

        async with SessionLocal() as db:
            with pytest.raises(AppError) as excinfo:
                await process_scan(
                    db,
                    tenant_id=tenant_b["tenant_id"],
                    store_id=tenant_a["store_id"],
                    session_id=session_a.id,
                    actor_id=tenant_b["user_id"],
                    image=b"x",
                    vision_port=port,
                )
        assert excinfo.value.status_code == 404
        assert port.calls == 0
    finally:
        await cleanup_tenant(tenant_a)
        await cleanup_tenant(tenant_b)


# ── 3. Store isolation ──────────────────────────────────────────────────────


async def test_scan_store_isolation(tenant_creds):
    env = await _scan_env(tenant_creds)
    other_store = Store(tenant_id=tenant_creds["tenant_id"], name="North")
    async with SessionLocal() as db:
        db.add(other_store)
        await db.commit()
        await db.refresh(other_store)

    session_a = await _create(tenant_creds, shelf_id=env["shelf_id"])
    port = FakeVisionPort([_barcode_item(BARCODE_A, 1)])

    async with SessionLocal() as db:
        with pytest.raises(AppError) as excinfo:
            await process_scan(
                db,
                tenant_id=tenant_creds["tenant_id"],
                store_id=other_store.id,
                session_id=session_a.id,
                actor_id=tenant_creds["user_id"],
                image=b"x",
                vision_port=port,
            )
    assert excinfo.value.status_code == 404
    assert port.calls == 0

    async with SessionLocal() as db:
        session_b = await create_scan_session(
            db, tenant_id=tenant_creds["tenant_id"], store_id=other_store.id, actor_id=tenant_creds["user_id"]
        )
    assert session_b.store_id == other_store.id


# ── 4. Shelf isolation ──────────────────────────────────────────────────────


async def test_scan_shelf_isolation():
    tenant_a = await make_tenant(f"owner-a-{uuid.uuid4().hex[:8]}@test.dev")
    tenant_b = await make_tenant(f"owner-b-{uuid.uuid4().hex[:8]}@test.dev")
    try:
        env_a = await _scan_env(tenant_a)

        async with SessionLocal() as db:
            with pytest.raises(AppError) as excinfo:
                await create_scan_session(
                    db,
                    tenant_id=tenant_b["tenant_id"],
                    store_id=tenant_b["store_id"],
                    actor_id=tenant_b["user_id"],
                    shelf_id=env_a["shelf_id"],
                )
        assert excinfo.value.status_code == 404
    finally:
        await cleanup_tenant(tenant_a)
        await cleanup_tenant(tenant_b)


# ── 5. Product resolution isolation ─────────────────────────────────────────


async def test_product_resolution_isolation():
    tenant_a = await make_tenant(f"owner-a-{uuid.uuid4().hex[:8]}@test.dev")
    tenant_b = await make_tenant(f"owner-b-{uuid.uuid4().hex[:8]}@test.dev")
    try:
        env_a = await _scan_env(tenant_a)
        env_b = await _scan_env(tenant_b)
        port = FakeVisionPort([_barcode_item(BARCODE_A, 2)])

        session_a = await _create(tenant_a)
        await _process(tenant_a, session_a.id, port)
        det_a = (await _detections(session_a.id))[0]
        assert det_a.product_id == env_a["product_a"]

        session_b = await _create(tenant_b)
        await _process(tenant_b, session_b.id, port)
        det_b = (await _detections(session_b.id))[0]
        assert det_b.product_id == env_b["product_a"]
        assert det_b.product_id != env_a["product_a"]
    finally:
        await cleanup_tenant(tenant_a)
        await cleanup_tenant(tenant_b)


# ── 6. SKU resolution ───────────────────────────────────────────────────────


async def test_sku_resolution(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    port = FakeVisionPort([DetectedItem(method="ocr", detected_sku=SKU_A, confidence=Decimal("0.90"), quantity=Decimal(4))])
    await _process(tenant_creds, session.id, port)
    det = (await _detections(session.id))[0]
    assert det.product_id == env["product_a"]
    assert det.status == "accepted"


# ── 7. Barcode resolution ───────────────────────────────────────────────────


async def test_barcode_resolution(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 5)])
    await _process(tenant_creds, session.id, port)
    det = (await _detections(session.id))[0]
    assert det.product_id == env["product_a"]
    assert det.detected_barcode == BARCODE_A


# ── 8. Unknown product ──────────────────────────────────────────────────────


async def test_unknown_product_forces_needs_review(tenant_creds):
    await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item("9999999999999", 2)])
    result = await _process(tenant_creds, session.id, port)
    assert result.status == SESSION_STATUS_NEEDS_REVIEW
    det = (await _detections(session.id))[0]
    assert det.product_id is None
    assert det.status == "needs_review"
    assert (await _reconciliations(session.id)) == []


# ── 9. Centralized confidence threshold ─────────────────────────────────────


async def test_confidence_threshold_boundary(tenant_creds):
    env = await _scan_env(tenant_creds)
    threshold = get_settings().ai_confidence_threshold
    assert threshold == 0.70

    below = await _create(tenant_creds)
    port_below = FakeVisionPort([_barcode_item(BARCODE_A, 1, confidence=Decimal("0.69"))])
    await _process(tenant_creds, below.id, port_below)
    assert (await _detections(below.id))[0].status == "needs_review"

    at_threshold = await _create(tenant_creds)
    port_at = FakeVisionPort([_barcode_item(BARCODE_A, 1, confidence=Decimal("0.70"))])
    await _process(tenant_creds, at_threshold.id, port_at)
    assert (await _detections(at_threshold.id))[0].status == "accepted"
    assert env is not None


# ── 10. NEEDS_REVIEW from low confidence ────────────────────────────────────


async def test_low_confidence_produces_needs_review(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    port = FakeVisionPort(
        [
            _barcode_item(BARCODE_A, 3, confidence=Decimal("0.95")),
            _barcode_item(BARCODE_B, 1, confidence=Decimal("0.50")),
        ]
    )
    result = await _process(tenant_creds, session.id, port)
    assert result.status == SESSION_STATUS_NEEDS_REVIEW
    dets = await _detections(session.id)
    by_product = {d.product_id: d for d in dets}
    assert by_product[env["product_a"]].status == "accepted"
    assert by_product[env["product_b"]].status == "needs_review"


# ── 11. Deterministic aggregation ───────────────────────────────────────────


async def test_deterministic_aggregation(tenant_creds):
    env = await _scan_env(tenant_creds)

    session_1 = await _create(tenant_creds)
    port_1 = FakeVisionPort(
        [
            _barcode_item(BARCODE_A, 3),
            _barcode_item(BARCODE_B, 2),
            _barcode_item(BARCODE_A, 1),
        ]
    )
    await _process(tenant_creds, session_1.id, port_1)

    session_2 = await _create(tenant_creds)
    port_2 = FakeVisionPort(
        [
            _barcode_item(BARCODE_A, 1),
            _barcode_item(BARCODE_B, 2),
            _barcode_item(BARCODE_A, 3),
        ]
    )
    await _process(tenant_creds, session_2.id, port_2)

    recs_1 = {r.product_id: r for r in await _reconciliations(session_1.id)}
    recs_2 = {r.product_id: r for r in await _reconciliations(session_2.id)}
    assert recs_1[env["product_a"]].detected_quantity == recs_2[env["product_a"]].detected_quantity == Decimal(4)
    assert recs_1[env["product_b"]].detected_quantity == recs_2[env["product_b"]].detected_quantity == Decimal(2)
    assert recs_1[env["product_a"]].variance == recs_2[env["product_a"]].variance


# ── 12. Duplicate / idempotent processing ───────────────────────────────────


async def test_duplicate_processing_rejected(tenant_creds):
    await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 3)])

    await _process(tenant_creds, session.id, port)
    dets_after_first = await _detections(session.id)
    recs_after_first = await _reconciliations(session.id)

    async with SessionLocal() as db:
        with pytest.raises(AppError) as excinfo:
            await process_scan(
                db,
                tenant_id=tenant_creds["tenant_id"],
                store_id=tenant_creds["store_id"],
                session_id=session.id,
                actor_id=tenant_creds["user_id"],
                image=b"x",
                vision_port=port,
            )
    assert excinfo.value.status_code == 409
    assert port.calls == 1

    assert len(await _detections(session.id)) == len(dets_after_first)
    assert len(await _reconciliations(session.id)) == len(recs_after_first)


# ── 13. Failed vision processing → deterministic FAILED ─────────────────────


async def test_failed_processing_marks_session_failed(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)
    port = FakeVisionPort(raise_error=True)

    async with SessionLocal() as db:
        with pytest.raises(AppError) as excinfo:
            await process_scan(
                db,
                tenant_id=tenant_creds["tenant_id"],
                store_id=tenant_creds["store_id"],
                session_id=session.id,
                actor_id=tenant_creds["user_id"],
                image=b"x",
                vision_port=port,
            )
    assert excinfo.value.status_code == 500

    async with SessionLocal() as db:
        loaded = (await db.execute(select(ScanSession).where(ScanSession.id == session.id))).scalar_one()
        assert loaded.status == SESSION_STATUS_FAILED
        assert loaded.completed_at is not None
    assert await _detections(session.id) == []
    assert await _reconciliations(session.id) == []
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(10)


# ── 14/15. No inventory mutation / no stock movement during processing ──────


async def test_processing_does_not_mutate_inventory_or_movements(tenant_creds):
    env = await _scan_env(tenant_creds)
    store_id = tenant_creds["store_id"]
    moves_before = await _movement_count(store_id)

    session = await _create(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_B, 2)])
    await _process(tenant_creds, session.id, port)

    assert await _inventory(store_id, env["product_a"]) == Decimal(10)
    assert await _inventory(store_id, env["product_b"]) == Decimal(10)
    assert await _movement_count(store_id) == moves_before


# ── Structural: service depends on the protocol only ────────────────────────


def test_service_depends_on_protocol_not_mock():
    import inspect

    from app.services import ai_service

    source = inspect.getsource(ai_service)
    assert "MockAIVisionPort" not in source
    assert "AIVisionPort" in source


async def test_fake_port_satisfies_protocol():
    assert isinstance(FakeVisionPort(), AIVisionPort)
