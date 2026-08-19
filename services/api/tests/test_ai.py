import uuid
from decimal import Decimal

import pytest
from conftest import api_client, login
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import selectinload

from app.core.db import SessionLocal
from app.models import ScanDetection, ScanReconciliation, ScanSession


async def _authed_client(creds: dict):
    login_resp = await login(creds)
    assert login_resp.status_code == 200
    token = login_resp.json()["access_token"]
    return await api_client(), {"Authorization": f"Bearer {token}"}


def _product_payload(**overrides):
    payload = {
        "name": "Milk 1L",
        "sku": "MILK-1L",
        "barcode": "5901234123457",
        "unit": "pcs",
        "cost_price": "2.10",
        "selling_price": "3.50",
        "reorder_point": "5",
        "reorder_quantity": "20",
    }
    payload.update(overrides)
    return payload


async def _make_scan_fixture(tenant_creds, client, headers):
    store_id = str(tenant_creds["store_id"])
    product = await client.post("/products", params={"store_id": store_id}, headers=headers, json=_product_payload())
    assert product.status_code == 201, product.text
    zone = await client.post(
        "/inventory/zones", params={"store_id": store_id}, headers=headers, json={"name": "AI Aisle"}
    )
    assert zone.status_code == 201, zone.text
    shelf = await client.post(
        "/inventory/shelves",
        params={"store_id": store_id},
        headers=headers,
        json={"zone_id": zone.json()["id"], "label": "AI Shelf"},
    )
    assert shelf.status_code == 201, shelf.text
    return {"product_id": uuid.UUID(product.json()["id"]), "shelf_id": uuid.UUID(shelf.json()["id"])}


async def _create_session(creds, shelf_id: uuid.UUID | None = None):
    async with SessionLocal() as db:
        session = ScanSession(
            tenant_id=creds["tenant_id"],
            store_id=creds["store_id"],
            shelf_id=shelf_id,
            status="processing",
            started_by=creds["user_id"],
            image_count=2,
        )
        db.add(session)
        await db.commit()
        await db.refresh(session)
        return session


async def test_scan_domain_roundtrip(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    async with client:
        fx = await _make_scan_fixture(tenant_creds, client, headers)
    session = await _create_session(tenant_creds, fx["shelf_id"])

    async with SessionLocal() as db:
        db.add_all(
            [
                ScanDetection(
                    tenant_id=tenant_creds["tenant_id"],
                    store_id=tenant_creds["store_id"],
                    session_id=session.id,
                    image_key="img1.jpg",
                    method="barcode",
                    product_id=fx["product_id"],
                    confidence=Decimal("0.9500"),
                    quantity_detected=Decimal(3),
                    status="accepted",
                    created_by=tenant_creds["user_id"],
                ),
                ScanDetection(
                    tenant_id=tenant_creds["tenant_id"],
                    store_id=tenant_creds["store_id"],
                    session_id=session.id,
                    image_key="img2.jpg",
                    method="visual",
                    confidence=Decimal("0.4200"),
                    quantity_detected=Decimal(2),
                    status="needs_review",
                    created_by=tenant_creds["user_id"],
                ),
                ScanReconciliation(
                    tenant_id=tenant_creds["tenant_id"],
                    store_id=tenant_creds["store_id"],
                    session_id=session.id,
                    product_id=fx["product_id"],
                    detected_quantity=Decimal(5),
                    system_quantity=Decimal(7),
                    variance=Decimal(-2),
                    status="needs_review",
                ),
            ]
        )
        await db.commit()

    async with SessionLocal() as db:
        loaded = (
            await db.execute(
                select(ScanSession)
                .options(selectinload(ScanSession.detections), selectinload(ScanSession.reconciliations))
                .where(ScanSession.id == session.id)
            )
        ).scalar_one()
        assert loaded.status == "processing"
        assert loaded.shelf_id == fx["shelf_id"]
        assert loaded.image_count == 2
        assert len(loaded.detections) == 2
        assert {d.status for d in loaded.detections} == {"accepted", "needs_review"}
        assert {d.method for d in loaded.detections} == {"barcode", "visual"}
        assert len(loaded.reconciliations) == 1
        assert loaded.reconciliations[0].variance == Decimal(-2)
        assert loaded.reconciliations[0].system_quantity == Decimal(7)

    async with SessionLocal() as db:
        await db.delete((await db.execute(select(ScanSession).where(ScanSession.id == session.id))).scalar_one())
        await db.commit()
        det_count = (
            await db.execute(select(func.count()).select_from(ScanDetection).where(ScanDetection.session_id == session.id))
        ).scalar_one()
        rec_count = (
            await db.execute(
                select(func.count()).select_from(ScanReconciliation).where(ScanReconciliation.session_id == session.id)
            )
        ).scalar_one()
        assert det_count == 0
        assert rec_count == 0


async def test_scan_detection_quantity_must_be_positive(tenant_creds):
    session = await _create_session(tenant_creds)
    async with SessionLocal() as db:
        db.add(
            ScanDetection(
                tenant_id=tenant_creds["tenant_id"],
                store_id=tenant_creds["store_id"],
                session_id=session.id,
                method="manual",
                quantity_detected=Decimal(0),
            )
        )
        with pytest.raises(IntegrityError):
            await db.commit()


async def test_scan_detection_confidence_range_enforced(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    async with client:
        fx = await _make_scan_fixture(tenant_creds, client, headers)
    session = await _create_session(tenant_creds)
    async with SessionLocal() as db:
        db.add(
            ScanDetection(
                tenant_id=tenant_creds["tenant_id"],
                store_id=tenant_creds["store_id"],
                session_id=session.id,
                method="manual",
                product_id=fx["product_id"],
                confidence=Decimal("1.5"),
                quantity_detected=Decimal(1),
            )
        )
        with pytest.raises(IntegrityError):
            await db.commit()


async def test_scan_reconciliation_unique_per_session_product(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    async with client:
        fx = await _make_scan_fixture(tenant_creds, client, headers)
    session = await _create_session(tenant_creds)

    def _make_row():
        return ScanReconciliation(
            tenant_id=tenant_creds["tenant_id"],
            store_id=tenant_creds["store_id"],
            session_id=session.id,
            product_id=fx["product_id"],
            detected_quantity=Decimal(3),
            system_quantity=Decimal(3),
            variance=Decimal(0),
            status="no_change",
        )

    async with SessionLocal() as db:
        db.add(_make_row())
        await db.commit()
    async with SessionLocal() as db:
        db.add(_make_row())
        with pytest.raises(IntegrityError):
            await db.commit()
