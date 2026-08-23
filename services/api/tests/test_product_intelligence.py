"""Product intelligence tests.

Covers:
- Brand persistence on product create/update, null when absent.
- Category text resolution: exact, case-insensitive, fuzzy containment, no match.
- Visual recognition memory: write, lookup, idempotent upsert (hit_count),
  tenant/store isolation.
- Name/category normalization helpers.
- Fuzzy name resolution and brand+name resolution.
"""

import uuid
from decimal import Decimal

import pytest
from conftest import api_client, cleanup_tenant, login, make_tenant
from sqlalchemy import select

from app.core.db import SessionLocal
from app.models import ProductVisualRecognition
from app.services.ai_service import (
    _resolve_by_visual_recognition,
    _resolve_product_by_brand_name,
    _resolve_product_by_fuzzy_name,
    _upsert_visual_recognition,
)
from app.services.catalog_service import (
    normalize_category_text,
    normalize_product_name,
    resolve_category_by_text,
)


@pytest.fixture
async def other_tenant():
    creds = await make_tenant(f"owner-{uuid.uuid4().hex[:8]}@test.dev")
    yield creds
    await cleanup_tenant(creds)


async def _authed_client(creds: dict):
    login_resp = await login(creds)
    assert login_resp.status_code == 200
    token = login_resp.json()["access_token"]
    return await api_client(), {"Authorization": f"Bearer {token}"}


def _category_payload(name: str, code: str | None = None):
    return {"name": name, "code": code}


def _product_payload(name: str = "Milk 1L", **overrides):
    payload = {
        "name": name,
        "sku": f"SKU-{uuid.uuid4().hex[:12].upper()}",
        "unit": "pcs",
        "cost_price": "2.10",
        "selling_price": "3.50",
        "reorder_point": "5",
        "reorder_quantity": "20",
    }
    payload.update(overrides)
    return payload


async def _create_category(client, headers, store_id: str, name: str):
    resp = await client.post("/categories", params={"store_id": store_id}, headers=headers, json=_category_payload(name))
    assert resp.status_code == 201
    return resp.json()


async def _create_product(client, headers, store_id: str, **overrides):
    resp = await client.post("/products", params={"store_id": store_id}, headers=headers, json=_product_payload(**overrides))
    assert resp.status_code == 201
    return resp.json()


async def _get_product(client, headers, store_id: str, product_id: str):
    resp = await client.get(f"/products/{product_id}", params={"store_id": store_id}, headers=headers)
    assert resp.status_code == 200
    return resp.json()


async def _write_visual(creds, product_id, normalized_name, *, brand=None, source="user_confirm", confidence=None):
    async with SessionLocal() as db:
        await _upsert_visual_recognition(
            db,
            tenant_id=creds["tenant_id"],
            store_id=creds["store_id"],
            product_id=product_id,
            normalized_name=normalized_name,
            brand=brand,
            source=source,
            confidence=confidence,
            actor_id=creds["user_id"],
        )
        await db.commit()


async def _visual_row(tenant_id, store_id, normalized_name):
    async with SessionLocal() as db:
        return (
            await db.execute(
                select(ProductVisualRecognition).where(
                    ProductVisualRecognition.tenant_id == tenant_id,
                    ProductVisualRecognition.store_id == store_id,
                    ProductVisualRecognition.normalized_name == normalized_name,
                )
            )
        ).scalar_one_or_none()


async def test_brand_persists_on_create(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        created = await _create_product(client, headers, store_id, name="Tiger Chips", brand="Tiger")
        got = await _get_product(client, headers, store_id, created["id"])
    assert got["brand"] == "Tiger"


async def test_brand_persists_on_update(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        created = await _create_product(client, headers, store_id, name="Farm Milk")
        patched = await client.patch(
            f"/products/{created['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"brand": "Farm Fresh"},
        )
        assert patched.status_code == 200
        got = await _get_product(client, headers, store_id, created["id"])
    assert got["brand"] == "Farm Fresh"


async def test_brand_null_on_create(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        created = await _create_product(client, headers, store_id, name="Generic Water")
        got = await _get_product(client, headers, store_id, created["id"])
    assert got["brand"] is None


async def test_category_resolution_exact_match(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        category = await _create_category(client, headers, store_id, "Snacks")
    category_id = uuid.UUID(category["id"])

    async with SessionLocal() as db:
        resolved = await resolve_category_by_text(db, tenant_creds["tenant_id"], tenant_creds["store_id"], "Snacks")
    assert resolved == category_id


async def test_category_resolution_case_insensitive(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        category = await _create_category(client, headers, store_id, "Snacks")
    category_id = uuid.UUID(category["id"])

    async with SessionLocal() as db:
        resolved = await resolve_category_by_text(db, tenant_creds["tenant_id"], tenant_creds["store_id"], "snacks")
    assert resolved == category_id


async def test_category_resolution_fuzzy_match(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        category = await _create_category(client, headers, store_id, "Soft Drinks")
    category_id = uuid.UUID(category["id"])

    async with SessionLocal() as db:
        resolved = await resolve_category_by_text(db, tenant_creds["tenant_id"], tenant_creds["store_id"], "soft drink")
    assert resolved == category_id


async def test_category_resolution_no_match(tenant_creds):
    async with SessionLocal() as db:
        resolved = await resolve_category_by_text(
            db, tenant_creds["tenant_id"], tenant_creds["store_id"], "Nonexistent"
        )
    assert resolved is None


async def test_visual_recognition_write(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await _create_product(client, headers, store_id, name="Tiger Chips Hot Chili")
    product_id = uuid.UUID(product["id"])

    await _write_visual(
        tenant_creds,
        product_id,
        "tiger chips hot chili",
        brand="Tiger",
        confidence=Decimal("0.92"),
    )

    rec = await _visual_row(tenant_creds["tenant_id"], tenant_creds["store_id"], "tiger chips hot chili")
    assert rec is not None
    assert rec.product_id == product_id
    assert rec.brand == "Tiger"
    assert rec.source == "user_confirm"
    assert rec.hit_count == 1
    assert rec.created_by == tenant_creds["user_id"]

    async with SessionLocal() as db:
        resolved = await _resolve_by_visual_recognition(
            db, tenant_creds["tenant_id"], tenant_creds["store_id"], "tiger chips hot chili"
        )
    assert resolved is not None
    assert resolved.id == product_id


async def test_visual_recognition_idempotent(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await _create_product(client, headers, store_id, name="Coca Cola 330ml")
    product_id = uuid.UUID(product["id"])

    await _write_visual(tenant_creds, product_id, "coca cola 330ml", confidence=Decimal("0.80"))
    await _write_visual(tenant_creds, product_id, "coca cola 330ml", confidence=Decimal("0.90"))

    rec = await _visual_row(tenant_creds["tenant_id"], tenant_creds["store_id"], "coca cola 330ml")
    assert rec is not None
    assert rec.product_id == product_id
    assert rec.hit_count == 2
    assert float(rec.avg_confidence) == pytest.approx(0.85)


async def test_visual_recognition_tenant_isolation(tenant_creds, other_tenant):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await _create_product(client, headers, store_id, name="Pringles Original")

    await _write_visual(tenant_creds, uuid.UUID(product["id"]), "pringles original", brand="Pringles")

    rec_other = await _visual_row(other_tenant["tenant_id"], other_tenant["store_id"], "pringles original")
    assert rec_other is None

    async with SessionLocal() as db:
        resolved = await _resolve_by_visual_recognition(
            db, other_tenant["tenant_id"], other_tenant["store_id"], "pringles original"
        )
    assert resolved is None


def test_normalize_product_name():
    assert normalize_product_name("Tiger Chips Hot Chili!") == "tiger chips hot chili"
    assert normalize_product_name("  tiger \t chips \n hot  ") == "tiger chips hot"
    assert normalize_product_name("Tiger, Chips!") == "tiger chips"
    assert normalize_product_name("Tiger's Chips") == "tigers chips"


def test_normalize_category_text():
    assert normalize_category_text("SNACKS") == "snacks"
    assert normalize_category_text("  Soft   Drinks ") == "soft drinks"
    assert normalize_category_text("\tBakery\n") == "bakery"


async def test_fuzzy_name_resolution(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await _create_product(client, headers, store_id, name="Tiger Chips Hot Chili")
    product_id = uuid.UUID(product["id"])

    async with SessionLocal() as db:
        resolved = await _resolve_product_by_fuzzy_name(
            db, tenant_creds["tenant_id"], tenant_creds["store_id"], "Tiger Chips Hot"
        )
    assert resolved is not None
    assert resolved.id == product_id


async def test_brand_name_resolution(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await _create_product(client, headers, store_id, name="Tiger Chips", brand="Tiger")
    product_id = uuid.UUID(product["id"])

    async with SessionLocal() as db:
        resolved = await _resolve_product_by_brand_name(
            db, tenant_creds["tenant_id"], tenant_creds["store_id"], "Tiger Chips Hot", "Tiger"
        )
    assert resolved is not None
    assert resolved.id == product_id
