import json
import uuid
from decimal import Decimal

import pytest
from conftest import api_client, login
from sqlalchemy import func, select

from app.ai import get_vision_port
from app.ai.contract import DetectedItem, VisionContext
from app.ai.mock_vision import MAGIC, MockAIVisionPort, MockImagePayload, encode_mock_image
from app.ai.vision_port import AIVisionPort
from app.core.db import SessionLocal
from app.models import Inventory, StockMovement


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


def _ctx(creds) -> VisionContext:
    return VisionContext(tenant_id=creds["tenant_id"], store_id=creds["store_id"])


def _barcode_item() -> DetectedItem:
    return DetectedItem(
        method="barcode",
        detected_barcode="5901234123457",
        confidence=Decimal("0.9500"),
        quantity=Decimal(3),
    )


# ── Protocol wiring ─────────────────────────────────────────────────────────


async def test_port_factory_returns_protocol_compliant_adapter():
    from app.config import get_settings
    get_settings.cache_clear()
    try:
        s = get_settings()
        orig_provider = s.ai_vision_provider
        orig_key = s.ai_vision_api_key
        s.ai_vision_provider = ""
        s.ai_vision_api_key = ""
        try:
            port = get_vision_port()
            assert isinstance(port, AIVisionPort)
            assert isinstance(port, MockAIVisionPort)
        finally:
            s.ai_vision_provider = orig_provider
            s.ai_vision_api_key = orig_key
            get_settings.cache_clear()
    finally:
        get_settings.cache_clear()


# ── Deterministic decode ────────────────────────────────────────────────────


async def test_mock_decodes_payload_and_is_deterministic(tenant_creds):
    payload = MockImagePayload(
        items=[
            _barcode_item(),
            DetectedItem(
                method="visual",
                detected_sku="MILK-1L",
                confidence=Decimal("0.7200"),
                quantity=Decimal(2),
            ),
        ]
    )
    image = encode_mock_image(payload)
    port = MockAIVisionPort()
    ctx = _ctx(tenant_creds)
    first = await port.analyze_image(image, ctx)
    second = await port.analyze_image(image, ctx)

    assert first == second
    assert [i.method for i in first] == ["barcode", "visual"]
    assert [i.detected_barcode for i in first] == ["5901234123457", None]
    assert [i.detected_sku for i in first] == [None, "MILK-1L"]
    assert [i.quantity for i in first] == [Decimal(3), Decimal(2)]
    assert first[1].confidence == Decimal("0.7200")


async def test_mock_preserves_item_order(tenant_creds):
    payload = MockImagePayload(
        items=[
            DetectedItem(method="ocr", detected_sku="A", confidence=Decimal("0.6"), quantity=Decimal(1)),
            DetectedItem(method="ocr", detected_sku="B", confidence=Decimal("0.6"), quantity=Decimal(1)),
            DetectedItem(method="ocr", detected_sku="C", confidence=Decimal("0.6"), quantity=Decimal(1)),
        ]
    )
    got = await MockAIVisionPort().analyze_image(encode_mock_image(payload), _ctx(tenant_creds))
    assert [i.detected_sku for i in got] == ["A", "B", "C"]


# ── Fallback behaviour (deterministic) ──────────────────────────────────────


async def test_mock_fallback_for_unrecognized_input(tenant_creds):
    port = MockAIVisionPort()
    ctx = _ctx(tenant_creds)
    bad_inputs = [
        b"",
        b"not an image",
        b"\xff\xfe\x00 garbage",
        b"VS-MOCK-9\n{\"items\": []}",
        f"{MAGIC}\n".encode(),
        f"{MAGIC}\nnot json".encode(),
    ]
    for raw in bad_inputs:
        got = await port.analyze_image(raw, ctx)
        assert len(got) == 1, raw
        item = got[0]
        assert item.method == "visual"
        assert item.confidence == Decimal("0.4000")
        assert item.quantity == Decimal(1)
        assert item.detected_sku is None and item.detected_barcode is None


async def test_mock_falls_back_on_invalid_item(tenant_creds):
    bad_confidence = (f"{MAGIC}\n" + json.dumps(
        {"items": [{"method": "barcode", "detected_barcode": "x", "confidence": 1.2, "quantity": 1}]}
    )).encode()
    bad_quantity = (f"{MAGIC}\n" + json.dumps(
        {"items": [{"method": "barcode", "detected_barcode": "x", "confidence": 0.9, "quantity": 0}]}
    )).encode()
    manual_with_confidence = (f"{MAGIC}\n" + json.dumps(
        {"items": [{"method": "manual", "confidence": 0.9, "quantity": 1}]}
    )).encode()

    port = MockAIVisionPort()
    ctx = _ctx(tenant_creds)
    for raw in (bad_confidence, bad_quantity, manual_with_confidence):
        got = await port.analyze_image(raw, ctx)
        assert len(got) == 1
        assert got[0].method == "visual"
        assert got[0].confidence == Decimal("0.4000")


# ── Contract validation ─────────────────────────────────────────────────────


async def test_contract_requires_confidence_for_machine_methods():
    with pytest.raises(ValueError):
        DetectedItem(method="barcode", detected_barcode="123", quantity=Decimal(1))
    with pytest.raises(ValueError):
        DetectedItem(method="manual", confidence=Decimal("0.9000"), quantity=Decimal(1))


async def test_contract_rejects_out_of_range_values():
    with pytest.raises(ValueError):
        DetectedItem(method="barcode", detected_barcode="x", confidence=Decimal("1.5000"), quantity=Decimal(1))
    with pytest.raises(ValueError):
        DetectedItem(method="barcode", detected_barcode="x", confidence=Decimal("0.9500"), quantity=Decimal(0))


# ── No inventory mutation ───────────────────────────────────────────────────


async def test_adapter_never_mutates_inventory(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await client.post(
            "/products", params={"store_id": store_id}, headers=headers, json=_product_payload()
        )
        assert product.status_code == 201, product.text
        pid = uuid.UUID(product.json()["id"])
        opening = await client.post(
            f"/inventory/stock/{pid}/opening", params={"store_id": store_id}, headers=headers, json={"quantity": "10"}
        )
        assert opening.status_code == 201, opening.text

    async with SessionLocal() as db:
        before_qty = (await db.execute(select(Inventory).where(Inventory.product_id == pid))).scalar_one().quantity
        before_moves = (
            await db.execute(
                select(func.count()).select_from(StockMovement).where(StockMovement.product_id == pid)
            )
        ).scalar_one()

    image = encode_mock_image(MockImagePayload(items=[_barcode_item()]))
    await MockAIVisionPort().analyze_image(image, _ctx(tenant_creds))

    async with SessionLocal() as db:
        after_qty = (await db.execute(select(Inventory).where(Inventory.product_id == pid))).scalar_one().quantity
        after_moves = (
            await db.execute(
                select(func.count()).select_from(StockMovement).where(StockMovement.product_id == pid)
            )
        ).scalar_one()

    assert before_qty == after_qty == Decimal(10)
    assert before_moves == after_moves == 1
