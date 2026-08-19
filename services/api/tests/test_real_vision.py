"""Tests for M4-B external vision adapter (app/ai/real_vision.py).

Covers: configuration fallback, parsing (happy + malformed + fenced JSON + partial),
MIME detection, provider construction, timeout/error propagation, and the extended
_name-based resolution path.  Provider HTTP calls are mocked (no real network).
"""
from __future__ import annotations

import json
import uuid
from decimal import Decimal
from unittest.mock import AsyncMock, patch

import httpx
import pytest

from app.ai.contract import DetectedItem, VisionContext
from app.ai.real_vision import (
    OpenAIVisionProvider,
    RealAIVisionPort,
    _build_provider,
    _detect_mime,
    _parse_items,
)
from app.core.db import SessionLocal

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

TENANT_ID = uuid.uuid4()
STORE_ID = uuid.uuid4()
CTX = VisionContext(tenant_id=TENANT_ID, store_id=STORE_ID)

# Minimal valid provider response (OpenAI-style JSON string)
VALID_RESPONSE = json.dumps(
    {
        "items": [
            {
                "name": "Tiger Chips Hot Chili",
                "brand": "Tiger",
                "barcode": "6281037021054",
                "sku": "TC-HC-001",
                "category": "Snacks",
                "quantity": 1,
                "confidence": 0.93,
                "ocr_text": "Hot Chili 120g",
                "description": "crispy potato chips",
            }
        ]
    }
)

MULTI_ITEM_RESPONSE = json.dumps(
    {
        "items": [
            {"name": "Aqua Delta 600ml", "confidence": 0.91, "quantity": 3, "category": "Beverages"},
            {"name": "Unknown Brand X", "confidence": 0.35, "quantity": 1},
        ]
    }
)


# ---------------------------------------------------------------------------
# MIME detection
# ---------------------------------------------------------------------------


def test_detect_jpeg():
    assert _detect_mime(b"\xff\xd8\xff\xe0") == "image/jpeg"


def test_detect_png():
    assert _detect_mime(b"\x89PNG\r\n\x1a\n") == "image/png"


def test_detect_webp():
    assert _detect_mime(b"RIFF\x00\x00\x00\x00WEBP") == "image/webp"


def test_detect_unknown_defaults_jpeg():
    assert _detect_mime(b"\x00\x01\x02\x03") == "image/jpeg"


# ---------------------------------------------------------------------------
# Response parser
# ---------------------------------------------------------------------------


def test_parse_valid_single_item():
    items = _parse_items(VALID_RESPONSE)
    assert len(items) == 1
    item = items[0]
    assert item.method == "visual"
    assert item.detected_barcode == "6281037021054"
    assert item.detected_sku == "TC-HC-001"
    assert item.confidence == Decimal("0.93")
    assert item.quantity == Decimal(1)
    assert item.meta is not None
    assert item.meta["name"] == "Tiger Chips Hot Chili"
    assert item.meta["brand"] == "Tiger"


def test_parse_multi_item():
    items = _parse_items(MULTI_ITEM_RESPONSE)
    assert len(items) == 2
    assert items[0].meta["name"] == "Aqua Delta 600ml"
    assert items[0].quantity == Decimal(3)
    assert items[1].confidence == Decimal("0.35")


def test_parse_markdown_fenced_json():
    fenced = "```json\n" + VALID_RESPONSE + "\n```"
    items = _parse_items(fenced)
    assert len(items) == 1
    assert items[0].meta["name"] == "Tiger Chips Hot Chili"


def test_parse_markdown_fenced_without_label():
    fenced = "```\n" + VALID_RESPONSE + "\n```"
    items = _parse_items(fenced)
    assert len(items) == 1


def test_parse_raw_json_with_surrounding_text():
    text = "Here is the result:\n" + VALID_RESPONSE + "\nEnd of response."
    items = _parse_items(text)
    assert len(items) == 1


def test_parse_empty_items_array():
    items = _parse_items(json.dumps({"items": []}))
    assert items == []


def test_parse_malformed_json_returns_empty():
    items = _parse_items("this is not json at all")
    assert items == []


def test_parse_partial_entry_skipped_valid_kept():
    mixed = json.dumps(
        {
            "items": [
                "bad entry",
                {"name": "Tiger", "confidence": 0.8, "quantity": 1},
                {"name": None},
            ]
        }
    )
    items = _parse_items(mixed)
    # At least the valid entry is parsed; the string and bad dict are skipped
    assert len(items) >= 1
    assert items[0].meta["name"] == "Tiger"


def test_parse_quantity_zero_clamped_to_one():
    resp = json.dumps({"items": [{"name": "X", "confidence": 0.5, "quantity": 0}]})
    items = _parse_items(resp)
    assert items[0].quantity == Decimal(1)


def test_parse_no_barcode_no_sku_no_meta():
    resp = json.dumps({"items": [{"confidence": 0.7, "quantity": 2}]})
    items = _parse_items(resp)
    assert items[0].detected_barcode is None
    assert items[0].detected_sku is None
    assert items[0].meta is None or items[0].meta == {}


# ---------------------------------------------------------------------------
# Configuration fallback
# ---------------------------------------------------------------------------


def test_build_provider_returns_none_without_config():
    with patch("app.ai.real_vision.get_settings") as mock_settings:
        mock_settings.return_value = type(
            "S", (), {"ai_vision_provider": "", "ai_vision_api_key": ""}
        )()
        assert _build_provider() is None


def test_build_provider_warns_on_empty_key():
    with patch("app.ai.real_vision.get_settings") as mock_settings:
        mock_settings.return_value = type(
            "S", (), {"ai_vision_provider": "openai", "ai_vision_api_key": ""}
        )()
        assert _build_provider() is None


def test_build_provider_returns_openai():
    with patch("app.ai.real_vision.get_settings") as mock_settings:
        mock_settings.return_value = type(
            "S",
            (),
            {
                "ai_vision_provider": "openai",
                "ai_vision_api_key": "test-key-123",
                "ai_vision_model": "",
                "ai_vision_timeout": 30,
            },
        )()
        provider = _build_provider()
        assert isinstance(provider, OpenAIVisionProvider)


def test_build_provider_unknown_returns_none():
    with patch("app.ai.real_vision.get_settings") as mock_settings:
        mock_settings.return_value = type(
            "S", (), {"ai_vision_provider": "unknown", "ai_vision_api_key": "x"}
        )()
        assert _build_provider() is None


# ---------------------------------------------------------------------------
# RealAIVisionPort — mocked provider
# ---------------------------------------------------------------------------


def _make_real_port(raw_response: str) -> RealAIVisionPort:
    mock_provider = AsyncMock()
    mock_provider.analyze = AsyncMock(return_value=raw_response)
    return RealAIVisionPort(mock_provider)


@pytest.mark.asyncio
async def test_real_port_returns_parsed_items():
    port = _make_real_port(VALID_RESPONSE)
    items = await port.analyze_image(b"\xff\xd8\xff\xe0data", CTX)
    assert len(items) == 1
    assert items[0].meta["name"] == "Tiger Chips Hot Chili"


@pytest.mark.asyncio
async def test_real_port_empty_image_returns_empty():
    port = _make_real_port("[]")
    items = await port.analyze_image(b"", CTX)
    assert items == []


@pytest.mark.asyncio
async def test_real_port_timeout_propagates():
    mock_provider = AsyncMock()
    mock_provider.analyze = AsyncMock(side_effect=httpx.TimeoutException("timed out"))
    port = RealAIVisionPort(mock_provider)
    with pytest.raises(httpx.TimeoutException):
        await port.analyze_image(b"\xff\xd8\xff\xe0data", CTX)


@pytest.mark.asyncio
async def test_real_port_http_error_propagates():
    mock_provider = AsyncMock()
    response = httpx.Response(status_code=401, request=httpx.Request("POST", "https://x"))
    mock_provider.analyze = AsyncMock(
        side_effect=httpx.HTTPStatusError("Unauthorized", request=response.request, response=response)
    )
    port = RealAIVisionPort(mock_provider)
    with pytest.raises(httpx.HTTPStatusError):
        await port.analyze_image(b"\xff\xd8\xff\xe0data", CTX)


@pytest.mark.asyncio
async def test_real_port_malformed_response_returns_empty():
    port = _make_real_port("not json at all, just garbage text")
    items = await port.analyze_image(b"\xff\xd8\xff\xe0data", CTX)
    assert items == []


@pytest.mark.asyncio
async def test_real_port_provider_called_with_base64():
    mock_provider = AsyncMock()
    mock_provider.analyze = AsyncMock(return_value="[]")
    port = RealAIVisionPort(mock_provider)
    test_bytes = b"\xff\xd8\xff\xe0some-image-data"
    await port.analyze_image(test_bytes, CTX)
    call_args = mock_provider.analyze.call_args
    import base64

    expected_b64 = base64.b64encode(test_bytes).decode("ascii")
    assert call_args[0][0] == expected_b64
    assert call_args[0][1] == "image/jpeg"


# ---------------------------------------------------------------------------
# Composition root integration
# ---------------------------------------------------------------------------


def test_get_vision_port_returns_mock_when_no_config():
    from app.ai import get_vision_port
    from app.ai.mock_vision import MockAIVisionPort

    with patch("app.ai.real_vision.get_settings") as mock_settings:
        mock_settings.return_value = type(
            "S", (), {"ai_vision_provider": "", "ai_vision_api_key": ""}
        )()
        port = get_vision_port()
        assert isinstance(port, MockAIVisionPort)


def test_get_vision_port_returns_real_when_configured():
    from app.ai import get_vision_port
    from app.ai.real_vision import RealAIVisionPort

    with patch("app.ai.real_vision.get_settings") as mock_settings:
        mock_settings.return_value = type(
            "S",
            (),
            {
                "ai_vision_provider": "openai",
                "ai_vision_api_key": "test-key",
                "ai_vision_model": "",
                "ai_vision_timeout": 30,
            },
        )()
        port = get_vision_port()
        assert isinstance(port, RealAIVisionPort)


# ---------------------------------------------------------------------------
# Name-based product resolution (extended _resolve_product)
# ---------------------------------------------------------------------------

from conftest import api_client, login, make_tenant


async def _authed_client(creds):
    login_resp = await login(creds)
    assert login_resp.status_code == 200
    token = login_resp.json()["access_token"]
    return await api_client(), {"Authorization": f"Bearer {token}"}


def _product_payload(**overrides):
    payload = {
        "name": "Tiger Chips Hot Chili",
        "sku": "TGR-CHILI",
        "barcode": "6281037021054",
        "unit": "pcs",
        "cost_price": "2.00",
        "selling_price": "3.50",
        "reorder_point": "5",
        "reorder_quantity": "20",
    }
    payload.update(overrides)
    return payload


@pytest.mark.asyncio
async def test_name_resolution_exact_match(tenant_creds):
    """A vision detection with a name matching an existing product resolves it."""
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        resp = await client.post(
            "/products",
            params={"store_id": store_id},
            headers=headers,
            json=_product_payload(name="Tiger Chips Hot Chili", barcode=None),
        )
        assert resp.status_code == 201, resp.text
        product_id = uuid.UUID(resp.json()["id"])

    # Simulate a vision detection with name metadata but no barcode/sku
    from app.services.ai_service import _resolve_product

    item = DetectedItem(
        method="visual",
        confidence=Decimal("0.90"),
        quantity=Decimal(1),
        meta={"name": "Tiger Chips Hot Chili", "brand": "Tiger"},
    )
    async with SessionLocal() as db:
        resolved = await _resolve_product(db, tenant_creds["tenant_id"], tenant_creds["store_id"], item)
        assert resolved is not None
        assert resolved.id == product_id


@pytest.mark.asyncio
async def test_name_resolution_substring_match(tenant_creds):
    """A partial name (substring overlap) still resolves the product."""
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        resp = await client.post(
            "/products",
            params={"store_id": store_id},
            headers=headers,
            json=_product_payload(name="Tiger Chips Hot Chili", barcode=None),
        )
        assert resp.status_code == 201, resp.text
        product_id = uuid.UUID(resp.json()["id"])

    from app.services.ai_service import _resolve_product

    # Use a partial name that still has enough word overlap
    item = DetectedItem(
        method="visual",
        confidence=Decimal("0.80"),
        quantity=Decimal(1),
        meta={"name": "Tiger Chips"},
    )
    async with SessionLocal() as db:
        resolved = await _resolve_product(db, tenant_creds["tenant_id"], tenant_creds["store_id"], item)
        assert resolved is not None
        assert resolved.id == product_id


@pytest.mark.asyncio
async def test_name_resolution_no_match_returns_none(tenant_creds):
    """A vision detection with a name that does not match any product returns None."""
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        resp = await client.post(
            "/products",
            params={"store_id": store_id},
            headers=headers,
            json=_product_payload(name="Tiger Chips Hot Chili", barcode=None),
        )
        assert resp.status_code == 201, resp.text

    from app.services.ai_service import _resolve_product

    item = DetectedItem(
        method="visual",
        confidence=Decimal("0.60"),
        quantity=Decimal(1),
        meta={"name": "Completely Unrelated Product XYZ"},
    )
    async with SessionLocal() as db:
        resolved = await _resolve_product(db, tenant_creds["tenant_id"], tenant_creds["store_id"], item)
        assert resolved is None


@pytest.mark.asyncio
async def test_name_resolution_cross_tenant_isolation(tenant_creds):
    """Name resolution does not match products from other tenants."""
    from app.services.ai_service import _resolve_product

    # Create a product in a different tenant
    other_creds = await make_tenant(f"other-{uuid.uuid4().hex[:8]}@test.dev")
    client, headers = await _authed_client(other_creds)
    store_id = str(other_creds["store_id"])
    async with client:
        resp = await client.post(
            "/products",
            params={"store_id": store_id},
            headers=headers,
            json=_product_payload(name="Tiger Chips Hot Chili", barcode=None),
        )
        assert resp.status_code == 201, resp.text

    # Try to resolve from the original tenant — should NOT find the other tenant's product
    item = DetectedItem(
        method="visual",
        confidence=Decimal("0.95"),
        quantity=Decimal(1),
        meta={"name": "Tiger Chips Hot Chili"},
    )
    async with SessionLocal() as db:
        resolved = await _resolve_product(
            db, tenant_creds["tenant_id"], tenant_creds["store_id"], item
        )
        assert resolved is None


@pytest.mark.asyncio
async def test_barcode_takes_precedence_over_name(tenant_creds):
    """When both barcode and name are present, barcode resolution wins."""
    from app.services.ai_service import _resolve_product

    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        resp_a = await client.post(
            "/products",
            params={"store_id": store_id},
            headers=headers,
            json=_product_payload(name="Tiger Chips Hot Chili", barcode="1111111111111"),
        )
        assert resp_a.status_code == 201, resp_a.text
        resp_b = await client.post(
            "/products",
            params={"store_id": store_id},
            headers=headers,
            json=_product_payload(name="Aqua Water", barcode="2222222222222", sku="AQUA-600"),
        )
        assert resp_b.status_code == 201, resp_b.text

    # Detection has barcode of product A but name of product B — barcode wins
    item = DetectedItem(
        method="visual",
        confidence=Decimal("0.92"),
        quantity=Decimal(1),
        detected_barcode="1111111111111",
        meta={"name": "Aqua Water"},
    )
    async with SessionLocal() as db:
        resolved = await _resolve_product(db, tenant_creds["tenant_id"], tenant_creds["store_id"], item)
        assert resolved is not None
        assert resolved.name == "Tiger Chips Hot Chili"
