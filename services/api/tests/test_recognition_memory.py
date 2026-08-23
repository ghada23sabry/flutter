"""Recognition memory + external enrichment tests.

Covers:
- Recognition memory written on link_detection_to_product (with barcode).
- Recognition memory written on confirm_scan_session (with barcode).
- Recognition memory lookup in _resolve_product (step 5).
- Recognition memory NOT written when detection has no barcode.
- Recognition memory hit_count increments on repeated confirm.
- Recognition memory stale product (deactivated) returns None.
- Recognition memory scoped per (tenant, store).
- External enrichment fallback in _resolve_product (Open Food Facts mock).
"""

from decimal import Decimal
from unittest.mock import AsyncMock, patch

from sqlalchemy import select
from test_scan_service import (
    BARCODE_A,
    FakeVisionPort,
    _authed_client,
    _create,
    _process,
    _scan_env,
)

from app.ai.contract import DetectedItem
from app.core.db import SessionLocal
from app.models import ProductRecognition, ScanDetection, Store
from app.services.ai_service import _resolve_product, link_detection_to_product

# ── helpers ─────────────────────────────────────────────────────────────────


async def _recognition(tenant_id, store_id, barcode):
    async with SessionLocal() as db:
        return (
            await db.execute(
                select(ProductRecognition).where(
                    ProductRecognition.tenant_id == tenant_id,
                    ProductRecognition.store_id == store_id,
                    ProductRecognition.barcode == barcode,
                )
            )
        ).scalar_one_or_none()


async def _recognition_count(tenant_id, store_id):
    async with SessionLocal() as db:
        result = await db.execute(
            select(ProductRecognition).where(
                ProductRecognition.tenant_id == tenant_id,
                ProductRecognition.store_id == store_id,
            )
        )
        return len(result.scalars().all())


async def _link_via_service(creds, session_id, detection_id, product_id):
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


async def _detections_for(session_id):
    async with SessionLocal() as db:
        rows = (
            await db.execute(
                select(ScanDetection)
                .where(ScanDetection.session_id == session_id)
                .order_by(ScanDetection.created_at)
            )
        ).scalars().all()
        return list(rows)


# ── 1. Link writes recognition memory (with unknown barcode) ───────────────


async def test_link_writes_recognition_with_unknown_barcode(tenant_creds):
    creds = tenant_creds
    env = await _scan_env(creds)
    unknown_barcode = "9999999999999"

    session = await _create(creds, shelf_id=env["shelf_id"])
    port = FakeVisionPort([
        DetectedItem(
            method="barcode",
            detected_barcode=unknown_barcode,
            confidence=Decimal("0.95"),
            quantity=Decimal(5),
        ),
    ])
    await _process(creds, session.id, port)
    dets = await _detections_for(session.id)
    assert len(dets) == 1
    det = dets[0]
    assert det.detected_barcode == unknown_barcode
    assert det.product_id is None

    await _link_via_service(creds, session.id, det.id, env["product_a"])

    rec = await _recognition(creds["tenant_id"], creds["store_id"], unknown_barcode)
    assert rec is not None
    assert rec.product_id == env["product_a"]
    assert rec.source == "link"
    assert rec.hit_count == 1


# ── 2. No barcode → no recognition memory ──────────────────────────────────


async def test_link_no_barcode_skips_recognition(tenant_creds):
    creds = tenant_creds
    env = await _scan_env(creds)

    session = await _create(creds, shelf_id=env["shelf_id"])
    # Process with an unknown barcode so session advances to completed
    port = FakeVisionPort([
        DetectedItem(
            method="barcode",
            detected_barcode="9999999999999",
            confidence=Decimal("0.95"),
            quantity=Decimal(5),
        ),
    ])
    await _process(creds, session.id, port)
    await _detections_for(session.id)

    # Now create a manual detection without barcode and link it
    async with SessionLocal() as db:
        det = ScanDetection(
            tenant_id=creds["tenant_id"],
            store_id=creds["store_id"],
            session_id=session.id,
            method="manual",
            detected_barcode=None,
            detected_sku=None,
            quantity_detected=Decimal(1),
            status="accepted",
        )
        db.add(det)
        await db.commit()
        await db.refresh(det)
        det_id = det.id

    await _link_via_service(creds, session.id, det_id, env["product_a"])

    count = await _recognition_count(creds["tenant_id"], creds["store_id"])
    assert count == 0


# ── 3. Confirm writes recognition memory (link + confirm = 2 writes) ──────


async def test_confirm_writes_recognition_memory(tenant_creds):
    creds = tenant_creds
    env = await _scan_env(creds)
    client, headers = await _authed_client(creds)
    store_id = str(creds["store_id"])
    unknown_barcode = "8888888888888"

    async with client:
        session = await _create(creds, shelf_id=env["shelf_id"])
        port = FakeVisionPort([
            DetectedItem(
                method="barcode",
                detected_barcode=unknown_barcode,
                confidence=Decimal("0.95"),
                quantity=Decimal(5),
            ),
        ])
        await _process(creds, session.id, port)
        dets = await _detections_for(session.id)
        det = dets[0]
        assert det.product_id is None

        await _link_via_service(creds, session.id, det.id, env["product_a"])

        resp = await client.post(
            f"/ai/scans/{session.id}/confirm",
            params={"store_id": store_id},
            headers=headers,
        )
        assert resp.status_code == 200

        rec = await _recognition(creds["tenant_id"], creds["store_id"], unknown_barcode)
        assert rec is not None
        assert rec.product_id == env["product_a"]
        # Link writes first (hit_count=1), confirm writes second (hit_count=2)
        assert rec.source == "user_confirm"
        assert rec.hit_count == 2


# ── 4. Confirm writes recognition even without link (direct resolve) ──────


async def test_confirm_writes_recognition_for_resolved_detection(tenant_creds):
    """When detection is already resolved by process_scan (barcode in catalog), confirm still writes memory."""
    creds = tenant_creds
    env = await _scan_env(creds)
    client, headers = await _authed_client(creds)
    store_id = str(creds["store_id"])

    async with client:
        session = await _create(creds, shelf_id=env["shelf_id"])
        port = FakeVisionPort([
            DetectedItem(
                method="barcode",
                detected_barcode=BARCODE_A,
                confidence=Decimal("0.95"),
                quantity=Decimal(5),
            ),
        ])
        await _process(creds, session.id, port)
        dets = await _detections_for(session.id)
        det = dets[0]
        # process_scan resolved this to product_a via catalog barcode match
        assert det.product_id == env["product_a"]

        resp = await client.post(
            f"/ai/scans/{session.id}/confirm",
            params={"store_id": store_id},
            headers=headers,
        )
        assert resp.status_code == 200

        rec = await _recognition(creds["tenant_id"], creds["store_id"], BARCODE_A)
        assert rec is not None
        assert rec.product_id == env["product_a"]
        assert rec.source == "user_confirm"
        assert rec.hit_count == 1


# ── 5. Recognition memory lookup in _resolve_product ───────────────────────


async def test_resolve_product_uses_recognition_memory(tenant_creds):
    creds = tenant_creds
    env = await _scan_env(creds)
    unknown_barcode = "7777777777777"

    async with SessionLocal() as db:
        db.add(ProductRecognition(
            tenant_id=creds["tenant_id"],
            store_id=creds["store_id"],
            barcode=unknown_barcode,
            product_id=env["product_a"],
            source="user_confirm",
            hit_count=5,
        ))
        await db.commit()

    item = DetectedItem(
        method="barcode",
        detected_barcode=unknown_barcode,
        confidence=Decimal("0.95"),
        quantity=Decimal(3),
    )

    async with SessionLocal() as db:
        product = await _resolve_product(db, creds["tenant_id"], creds["store_id"], item)
        assert product is not None
        assert product.id == env["product_a"]

    # Verify the memory row exists (hit_count increment happens in the
    # same session that called _resolve_product; the caller commits later.
    # We just verify the row is present and points to the right product.)
    rec = await _recognition(creds["tenant_id"], creds["store_id"], unknown_barcode)
    assert rec is not None
    assert rec.product_id == env["product_a"]


# ── 6. Stale recognition (deactivated product) → None ─────────────────────


async def test_resolve_product_recognition_stale_product(tenant_creds):
    creds = tenant_creds
    env = await _scan_env(creds)
    unknown_barcode = "6666666666666"

    async with SessionLocal() as db:
        from app.models import Product
        product = (
            await db.execute(
                select(Product).where(Product.id == env["product_a"])
            )
        ).scalar_one()
        product.status = "inactive"
        await db.commit()

    async with SessionLocal() as db:
        db.add(ProductRecognition(
            tenant_id=creds["tenant_id"],
            store_id=creds["store_id"],
            barcode=unknown_barcode,
            product_id=env["product_a"],
            source="user_confirm",
        ))
        await db.commit()

    item = DetectedItem(
        method="barcode",
        detected_barcode=unknown_barcode,
        confidence=Decimal("0.95"),
        quantity=Decimal(3),
    )

    async with SessionLocal() as db:
        product = await _resolve_product(db, creds["tenant_id"], creds["store_id"], item)
        assert product is None


# ── 7. hit_count increments on repeated confirm ────────────────────────────


async def test_confirm_increments_hit_count(tenant_creds):
    creds = tenant_creds
    env = await _scan_env(creds)
    client, headers = await _authed_client(creds)
    store_id = str(creds["store_id"])
    barcode = "5555555555555"

    async with client:
        # First confirm (link + confirm = hit_count 2)
        s1 = await _create(creds, shelf_id=env["shelf_id"])
        port1 = FakeVisionPort([
            DetectedItem(method="barcode", detected_barcode=barcode, confidence=Decimal("0.95"), quantity=Decimal(3)),
        ])
        await _process(creds, s1.id, port1)
        dets1 = await _detections_for(s1.id)
        await _link_via_service(creds, s1.id, dets1[0].id, env["product_a"])
        resp = await client.post(
            f"/ai/scans/{s1.id}/confirm",
            params={"store_id": store_id},
            headers=headers,
        )
        assert resp.status_code == 200

        rec = await _recognition(creds["tenant_id"], creds["store_id"], barcode)
        assert rec is not None
        assert rec.hit_count == 2

        # Second confirm (link + confirm = hit_count 4)
        s2 = await _create(creds, shelf_id=env["shelf_id"])
        port2 = FakeVisionPort([
            DetectedItem(method="barcode", detected_barcode=barcode, confidence=Decimal("0.95"), quantity=Decimal(7)),
        ])
        await _process(creds, s2.id, port2)
        dets2 = await _detections_for(s2.id)
        await _link_via_service(creds, s2.id, dets2[0].id, env["product_a"])
        resp = await client.post(
            f"/ai/scans/{s2.id}/confirm",
            params={"store_id": store_id},
            headers=headers,
        )
        assert resp.status_code == 200

        rec = await _recognition(creds["tenant_id"], creds["store_id"], barcode)
        assert rec is not None
        assert rec.hit_count == 4


# ── 8. Recognition scoped per store ────────────────────────────────────────


async def test_recognition_scoped_per_store(tenant_creds):
    creds = tenant_creds
    env = await _scan_env(creds)
    barcode = "4444444444444"

    async with SessionLocal() as db:
        db.add(ProductRecognition(
            tenant_id=creds["tenant_id"],
            store_id=creds["store_id"],
            barcode=barcode,
            product_id=env["product_a"],
            source="user_confirm",
        ))
        await db.commit()

    async with SessionLocal() as db:
        store2 = Store(tenant_id=creds["tenant_id"], name="Store 2")
        db.add(store2)
        await db.commit()
        await db.refresh(store2)

    item = DetectedItem(
        method="barcode",
        detected_barcode=barcode,
        confidence=Decimal("0.95"),
        quantity=Decimal(1),
    )
    async with SessionLocal() as db:
        product = await _resolve_product(db, creds["tenant_id"], store2.id, item)
        assert product is None


# ── 9. External enrichment mock (OFF name matches) ────────────────────────


async def test_resolve_uses_off_enrichment_when_name_matches(tenant_creds):
    creds = tenant_creds
    env = await _scan_env(creds)
    unknown_barcode = "3333333333333"

    mock_result = type("MockResult", (), {
        "barcode": unknown_barcode,
        "name": "Milk 1L",
        "brand": "TestBrand",
        "category": "Dairy",
        "description": "Fresh milk",
        "has_name": True,
    })()

    item = DetectedItem(
        method="barcode",
        detected_barcode=unknown_barcode,
        confidence=Decimal("0.95"),
        quantity=Decimal(3),
    )

    with patch("app.services.ai_service.enrich_barcode_off", new_callable=AsyncMock, return_value=mock_result):
        async with SessionLocal() as db:
            product = await _resolve_product(db, creds["tenant_id"], creds["store_id"], item)
            assert product is not None
            assert product.id == env["product_a"]


# ── 10. External enrichment returns no name → None ────────────────────────


async def test_resolve_skips_off_when_no_name(tenant_creds):
    creds = tenant_creds
    unknown_barcode = "2222222222222"

    mock_result = type("MockResult", (), {
        "barcode": unknown_barcode,
        "name": None,
        "has_name": False,
    })()

    item = DetectedItem(
        method="barcode",
        detected_barcode=unknown_barcode,
        confidence=Decimal("0.95"),
        quantity=Decimal(3),
    )

    with patch("app.services.ai_service.enrich_barcode_off", new_callable=AsyncMock, return_value=mock_result):
        async with SessionLocal() as db:
            product = await _resolve_product(db, creds["tenant_id"], creds["store_id"], item)
            assert product is None
