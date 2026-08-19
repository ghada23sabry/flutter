import uuid
from datetime import timedelta
from decimal import Decimal

from conftest import api_client, cleanup_tenant, login, make_tenant
from sqlalchemy import select

from app.core.db import SessionLocal
from app.core.security import hash_password
from app.models import Inventory, Permission, Role, RolePermission, StockMovement, Store, User, UserRole, Zone
from app.services.inventory_service import today_utc


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
        "expiry_tracking_enabled": True,
    }
    payload.update(overrides)
    return payload


async def _create_product(client, headers, store_id: str, **overrides):
    resp = await client.post("/products", params={"store_id": store_id}, headers=headers, json=_product_payload(**overrides))
    assert resp.status_code == 201, resp.text
    return resp.json()


async def _open_stock(client, headers, store_id: str, product_id: str, quantity="10", **overrides):
    body = {"quantity": quantity}
    body.update(overrides)
    resp = await client.post(
        f"/inventory/stock/{product_id}/opening", params={"store_id": store_id}, headers=headers, json=body
    )
    return resp


# ── Auth / permission gates ────────────────────────────────────────────────


async def test_inventory_requires_auth(tenant_creds):
    async with await api_client() as client:
        resp = await client.get("/inventory/zones", params={"store_id": str(tenant_creds["store_id"])})
    assert resp.status_code == 401
    assert resp.json()["detail"]["code"] == "UNAUTHORIZED"


async def test_inventory_view_forbidden_without_permission(tenant_creds):
    async with SessionLocal() as db:
        cashier_email = f"limited-{uuid.uuid4().hex[:8]}@test.dev"
        cashier = User(
            tenant_id=tenant_creds["tenant_id"],
            email=cashier_email,
            name="Cashier",
            password_hash=hash_password("Passw0rd!"),
        )
        db.add(cashier)
        await db.flush()
        role = Role(tenant_id=tenant_creds["tenant_id"], name="NoInv", description="no inventory access")
        db.add(role)
        await db.flush()
        sales_perm = (await db.execute(select(Permission).where(Permission.code == "sales.create"))).scalar_one()
        db.add(RolePermission(role_id=role.id, permission_id=sales_perm.id))
        db.add(UserRole(user_id=cashier.id, role_id=role.id, store_id=tenant_creds["store_id"]))
        await db.commit()

    resp = await login({"email": cashier_email, "password": "Passw0rd!"})
    token = resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    async with await api_client() as client:
        zones = await client.get("/inventory/zones", params={"store_id": str(tenant_creds["store_id"])}, headers=headers)
        opening = await client.post(
            f"/inventory/stock/{uuid.uuid4()}/opening",
            params={"store_id": str(tenant_creds["store_id"])},
            headers=headers,
            json={"quantity": "1"},
        )
    assert zones.status_code == 403
    assert opening.status_code == 403


async def test_inventory_rbac_boundaries(tenant_creds):
    """M3 §9: inventory.view allows reads; missing adjust/layout/expiry/movements → 403."""
    async with SessionLocal() as db:
        email = f"inv-viewer-{uuid.uuid4().hex[:8]}@test.dev"
        user = User(
            tenant_id=tenant_creds["tenant_id"],
            email=email,
            name="Inv Viewer",
            password_hash=hash_password("Passw0rd!"),
        )
        db.add(user)
        await db.flush()
        role = Role(tenant_id=tenant_creds["tenant_id"], name="InvView", description="inventory view only")
        db.add(role)
        await db.flush()
        perm = (await db.execute(select(Permission).where(Permission.code == "inventory.view"))).scalar_one()
        db.add(RolePermission(role_id=role.id, permission_id=perm.id))
        db.add(UserRole(user_id=user.id, role_id=role.id, store_id=tenant_creds["store_id"]))
        await db.commit()

    resp = await login({"email": email, "password": "Passw0rd!"})
    assert resp.status_code == 200
    token = resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    store_id = str(tenant_creds["store_id"])

    client, owner_headers = await _authed_client(tenant_creds)
    async with client:
        product = await _create_product(client, owner_headers, store_id)

    async with await api_client() as client:
        zones = await client.get("/inventory/zones", params={"store_id": store_id}, headers=headers)
        stock = await client.get("/inventory/stock", params={"store_id": store_id}, headers=headers)
        detail = await client.get(
            f"/inventory/stock/{product['id']}", params={"store_id": store_id}, headers=headers
        )
        adjust = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"delta": "1", "reason": "denied"},
        )
        create_zone = await client.post(
            "/inventory/zones", params={"store_id": store_id}, headers=headers, json={"name": "Z"}
        )
        create_shelf = await client.post(
            "/inventory/shelves",
            params={"store_id": store_id},
            headers=headers,
            json={"zone_id": str(uuid.uuid4()), "label": "S"},
        )
        create_batch = await client.post(
            "/inventory/expiry",
            params={"store_id": store_id},
            headers=headers,
            json={"product_id": product["id"], "quantity": "1", "expiry_date": "2030-01-01"},
        )
        write_off = await client.post(
            f"/inventory/expiry/{uuid.uuid4()}/write-off",
            params={"store_id": store_id},
            headers=headers,
            json={"quantity": "1", "reason": "denied"},
        )
        movements = await client.get("/inventory/movements", params={"store_id": store_id}, headers=headers)

    assert zones.status_code == 200
    assert stock.status_code == 200
    assert detail.status_code == 200
    assert adjust.status_code == 403
    assert create_zone.status_code == 403
    assert create_shelf.status_code == 403
    assert create_batch.status_code == 403
    assert write_off.status_code == 403
    assert movements.status_code == 403


# ── Zones ──────────────────────────────────────────────────────────────────


async def test_zone_crud_and_duplicate(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        created = await client.post(
            "/inventory/zones", params={"store_id": store_id}, headers=headers, json={"name": "Cold Aisle", "code": "cold-1"}
        )
        assert created.status_code == 201, created.text
        assert created.json()["code"] == "COLD-1"
        assert created.json()["status"] == "active"

        listed = await client.get("/inventory/zones", params={"store_id": store_id}, headers=headers)
        assert listed.status_code == 200
        assert [z["id"] for z in listed.json()] == [created.json()["id"]]

        updated = await client.patch(
            f"/inventory/zones/{created.json()['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"name": "Cold Aisle B", "status": "inactive"},
        )
        assert updated.status_code == 200
        assert updated.json()["name"] == "Cold Aisle B"
        assert updated.json()["status"] == "inactive"

        dup = await client.post(
            "/inventory/zones", params={"store_id": store_id}, headers=headers, json={"name": "X", "code": "cold-1"}
        )
        assert dup.status_code == 409
        assert dup.json()["detail"]["code"] == "CONFLICT"


async def test_zone_cross_tenant_isolation():
    tenant_a = await make_tenant(f"owner-a-{uuid.uuid4().hex[:8]}@test.dev")
    tenant_b = await make_tenant(f"owner-b-{uuid.uuid4().hex[:8]}@test.dev")
    try:
        client_a, headers_a = await _authed_client(tenant_a)
        client_b, headers_b = await _authed_client(tenant_b)
        async with client_a:
            zone = await client_a.post(
                "/inventory/zones",
                params={"store_id": str(tenant_a["store_id"])},
                headers=headers_a,
                json={"name": "Secret Aisle"},
            )
        async with client_b:
            got = await client_b.get(
                f"/inventory/zones/{zone.json()['id']}", params={"store_id": str(tenant_b["store_id"])}, headers=headers_b
            )
        assert got.status_code == 404
        assert got.json()["detail"]["code"] == "NOT_FOUND"
    finally:
        await cleanup_tenant(tenant_a)
        await cleanup_tenant(tenant_b)


# ── Shelves & product mapping ──────────────────────────────────────────────


async def test_shelf_crud_and_product_mapping(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        zone = await client.post(
            "/inventory/zones", params={"store_id": store_id}, headers=headers, json={"name": "Dairy"}
        )
        zone_id = zone.json()["id"]

        shelf = await client.post(
            "/inventory/shelves",
            params={"store_id": store_id},
            headers=headers,
            json={"zone_id": zone_id, "label": "Shelf 1", "position": 1},
        )
        assert shelf.status_code == 201, shelf.text
        assert shelf.json()["zone_name"] == "Dairy"
        shelf_id = shelf.json()["id"]

        product = await _create_product(client, headers, store_id)

        mapped = await client.post(
            f"/inventory/shelves/{shelf_id}/products",
            params={"store_id": store_id},
            headers=headers,
            json={"product_id": product["id"], "is_primary": True},
        )
        assert mapped.status_code == 201, mapped.text
        assert mapped.json()["product_name"] == "Milk 1L"

        dup = await client.post(
            f"/inventory/shelves/{shelf_id}/products",
            params={"store_id": store_id},
            headers=headers,
            json={"product_id": product["id"]},
        )
        assert dup.status_code == 409

        unmapped = await client.delete(
            f"/inventory/shelves/{shelf_id}/products/{product['id']}", params={"store_id": store_id}, headers=headers
        )
        assert unmapped.status_code == 200

        missing = await client.delete(
            f"/inventory/shelves/{shelf_id}/products/{product['id']}", params={"store_id": store_id}, headers=headers
        )
        assert missing.status_code == 404


async def test_shelf_requires_scoped_zone(tenant_creds):
    async with SessionLocal() as db:
        other = Store(tenant_id=tenant_creds["tenant_id"], name="Uptown")
        db.add(other)
        await db.flush()
        other_zone = Zone(tenant_id=tenant_creds["tenant_id"], store_id=other.id, name="Other Zone")
        db.add(other_zone)
        await db.flush()
        other_zone_id = str(other_zone.id)
        await db.commit()

    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await client.post(
            "/inventory/shelves",
            params={"store_id": str(tenant_creds["store_id"])},
            headers=headers,
            json={"zone_id": other_zone_id, "label": "Bad Shelf"},
        )
    assert resp.status_code == 404
    assert resp.json()["detail"]["code"] == "NOT_FOUND"


# ── Opening stock / adjustments / ledger ───────────────────────────────────


async def test_opening_stock_concurrent_single_winner(tenant_creds):
    """Two simultaneous openings must produce exactly one winner — no double stock."""
    import asyncio

    import httpx
    from httpx import ASGITransport

    from app.main import app

    client, headers = await _authed_client(tenant_creds)
    async with client:
        product = await _create_product(client, headers, str(tenant_creds["store_id"]))
    store_id = str(tenant_creds["store_id"])

    async def _open(quantity: str) -> int:
        login_resp = await login(tenant_creds)
        token = login_resp.json()["access_token"]
        async with httpx.AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            resp = await client.post(
                f"/inventory/stock/{product['id']}/opening",
                params={"store_id": store_id},
                headers={"Authorization": f"Bearer {token}"},
                json={"quantity": quantity},
            )
            return resp.status_code

    statuses = await asyncio.gather(_open("10"), _open("10"), _open("10"))
    assert sorted(statuses) == [201, 409, 409]

    async with SessionLocal() as db:
        rows = (
            await db.execute(
                select(StockMovement).where(
                    StockMovement.store_id == store_id,
                    StockMovement.product_id == product["id"],
                    StockMovement.movement_type == "OPENING",
                )
            )
        ).scalars().all()
        assert len(rows) == 1


async def test_opening_stock_then_adjustment_ledger(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await _create_product(client, headers, store_id)

        opened = await _open_stock(client, headers, store_id, product["id"])
        assert opened.status_code == 201, opened.text
        body = opened.json()
        assert body["quantity"] == "10.000"
        assert body["available_quantity"] == "10.000"
        assert body["has_opening"] is True
        assert body["stock_status"] == "healthy"

        double = await _open_stock(client, headers, store_id, product["id"], quantity="99")
        assert double.status_code == 409
        assert double.json()["detail"]["code"] == "CONFLICT"

        adjusted = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"new_quantity": "3", "reason": "stock count correction"},
        )
        assert adjusted.status_code == 200, adjusted.text
        assert adjusted.json()["quantity"] == "3.000"
        assert adjusted.json()["stock_status"] == "low_stock"

        lowered = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"new_quantity": "0", "reason": "waste"},
        )
        assert lowered.status_code == 200
        assert lowered.json()["stock_status"] == "out_of_stock"

        movements = await client.get("/inventory/movements", params={"store_id": store_id}, headers=headers)
        assert movements.status_code == 200
        items = movements.json()["items"]
        assert [m["movement_type"] for m in items] == ["ADJUSTMENT", "ADJUSTMENT", "OPENING"]
        assert items[2]["resulting_quantity"] == "10.000"
        assert items[2]["created_by_name"] == "Owner"


async def test_adjustment_without_opening_404(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await _create_product(client, headers, store_id)
        resp = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"new_quantity": "5", "reason": "count"},
        )
    assert resp.status_code == 404
    assert resp.json()["detail"]["code"] == "NOT_FOUND"


async def test_adjustment_concurrent_no_lost_update(tenant_creds):
    """M3 §7: concurrent +10 and +20 on 100 must serialize to 130 — no lost update.

    Uses the delta form, applied under `FOR UPDATE`, plus the monotonic version
    guard: exactly two version bumps and two ADJUSTMENT ledger rows.
    """
    import asyncio

    import httpx
    from httpx import ASGITransport

    from app.main import app

    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])

    async def _adjust(delta: str) -> int:
        login_resp = await login(tenant_creds)
        token = login_resp.json()["access_token"]
        async with httpx.AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            resp = await c.patch(
                f"/inventory/stock/{product['id']}",
                params={"store_id": store_id},
                headers={"Authorization": f"Bearer {token}"},
                json={"delta": delta, "reason": "concurrent stock-in"},
            )
            return resp.status_code

    async with client:
        product = await _create_product(client, headers, store_id)
        opened = await _open_stock(client, headers, store_id, product["id"], quantity="100")
        assert opened.status_code == 201, opened.text
        assert opened.json()["quantity"] == "100.000"

        statuses = await asyncio.gather(_adjust("10"), _adjust("20"))
        assert sorted(statuses) == [200, 200]

        detail = await client.get(
            f"/inventory/stock/{product['id']}", params={"store_id": store_id}, headers=headers
        )
        assert detail.status_code == 200
        assert detail.json()["quantity"] == "130.000"
        assert detail.json()["available_quantity"] == "130.000"
        assert detail.json()["stock_status"] == "healthy"

    async with SessionLocal() as db:
        inv = (
            await db.execute(
                select(Inventory).where(Inventory.store_id == tenant_creds["store_id"], Inventory.product_id == uuid.UUID(product["id"]))
            )
        ).scalar_one()
        assert inv.version == 2, "every adjustment must bump the optimistic version guard"

        rows = (
            await db.execute(
                select(StockMovement)
                .where(StockMovement.store_id == tenant_creds["store_id"], StockMovement.product_id == uuid.UUID(product["id"]))
                .order_by(StockMovement.created_at.asc())
            )
        ).scalars().all()
        assert [m.movement_type for m in rows] == ["OPENING", "ADJUSTMENT", "ADJUSTMENT"]
        deltas = sorted(m.quantity_delta for m in rows if m.movement_type == "ADJUSTMENT")
        assert deltas == [Decimal("10.000"), Decimal("20.000")]
        assert [m.resulting_quantity for m in rows] == [Decimal("100.000"), Decimal("110.000"), Decimal("130.000")]


async def test_adjustment_delta_form_and_validation(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await _create_product(client, headers, store_id)
        await _open_stock(client, headers, store_id, product["id"], quantity="10")

        lowered = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"delta": "-3", "reason": "waste"},
        )
        assert lowered.status_code == 200
        assert lowered.json()["quantity"] == "7.000"

        neither = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"reason": "no target"},
        )
        assert neither.status_code == 422

        both = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"new_quantity": "9", "delta": "1", "reason": "ambiguous"},
        )
        assert both.status_code == 422

        zero = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"delta": "0", "reason": "no-op"},
        )
        assert zero.status_code == 422

        negative = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"delta": "-99", "reason": "overdraft"},
        )
        assert negative.status_code == 422


async def test_adjustment_unchanged_rejected(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await _create_product(client, headers, store_id)
        await _open_stock(client, headers, store_id, product["id"], quantity="10")
        resp = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"new_quantity": "10", "reason": "no-op"},
        )
    assert resp.status_code == 422


# ── Expiry batches ─────────────────────────────────────────────────────────


async def test_expiry_batch_lifecycle(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    today = today_utc()
    async with client:
        product = await _create_product(client, headers, store_id)
        await _open_stock(client, headers, store_id, product["id"], quantity="10")

        batch = await client.post(
            "/inventory/expiry",
            params={"store_id": store_id},
            headers=headers,
            json={
                "product_id": product["id"],
                "quantity": "5",
                "expiry_date": (today + timedelta(days=10)).isoformat(),
                "batch_code": "B-1",
            },
        )
        assert batch.status_code == 201, batch.text
        batch_body = batch.json()
        assert batch_body["status"] == "near_expiry"
        assert batch_body["days_remaining"] == 10
        assert batch_body["quantity"] == "5.000"
        batch_id = batch_body["id"]

        detail = await client.get(f"/inventory/stock/{product['id']}", params={"store_id": store_id}, headers=headers)
        assert detail.json()["quantity"] == "15.000"
        assert detail.json()["expiry_batches"][0]["batch_code"] == "B-1"

        stale = await client.post(
            "/inventory/expiry",
            params={"store_id": store_id},
            headers=headers,
            json={
                "product_id": product["id"],
                "quantity": "2",
                "expiry_date": (today - timedelta(days=1)).isoformat(),
                "batch_code": "B-OLD",
            },
        )
        assert stale.json()["status"] == "expired"
        assert stale.json()["days_remaining"] == -1

        near = await client.get(
            "/inventory/expiry", params={"store_id": store_id, "status": "near_expiry"}, headers=headers
        )
        assert [b["id"] for b in near.json()] == [batch_id]

        updated = await client.patch(
            f"/inventory/expiry/{batch_id}",
            params={"store_id": store_id},
            headers=headers,
            json={"batch_code": "B-1-RENEWED"},
        )
        assert updated.status_code == 200
        assert updated.json()["batch_code"] == "B-1-RENEWED"

        deleted = await client.delete(f"/inventory/expiry/{batch_id}", params={"store_id": store_id}, headers=headers)
        assert deleted.status_code == 422  # remaining stock must be adjusted first


async def test_expiry_batch_requires_inventory(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await _create_product(client, headers, store_id)
        resp = await client.post(
            "/inventory/expiry",
            params={"store_id": store_id},
            headers=headers,
            json={"product_id": product["id"], "quantity": "5", "expiry_date": "2030-01-01"},
        )
    assert resp.status_code == 422


async def test_adjustment_drains_expiry_batch(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    today = today_utc()
    async with client:
        product = await _create_product(client, headers, store_id)
        await _open_stock(client, headers, store_id, product["id"], quantity="10", expiry_date=(today + timedelta(days=60)).isoformat())

        detail = await client.get(f"/inventory/stock/{product['id']}", params={"store_id": store_id}, headers=headers)
        batch_id = detail.json()["expiry_batches"][0]["id"]

        drained = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"new_quantity": "4", "reason": "sold batch", "expiry_batch_id": batch_id},
        )
        assert drained.status_code == 200, drained.text
        batch_out = drained.json()["expiry_batches"][0]
        assert batch_out["quantity"] == "4.000"
        assert drained.json()["quantity"] == "4.000"

        # add stock back WITHOUT a batch so the batch no longer backs the inventory
        restocked = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"new_quantity": "9", "reason": "restock"},
        )
        assert restocked.status_code == 200
        assert restocked.json()["quantity"] == "9.000"

        # draining 9 from a batch of 4 must be rejected
        too_much = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"new_quantity": "0", "reason": "overdrain", "expiry_batch_id": batch_id},
        )
        assert too_much.status_code == 422

        add_to_batch = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"new_quantity": "10", "reason": "cannot add", "expiry_batch_id": batch_id},
        )
        assert add_to_batch.status_code == 422


async def test_expiry_batch_write_off(tenant_creds):
    """Write-off drains batch + inventory, appends a WRITE_OFF ledger row, and
    the drained batch becomes deletable."""
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    today = today_utc()
    async with client:
        product = await _create_product(client, headers, store_id)
        opened = await _open_stock(
            client,
            headers,
            store_id,
            product["id"],
            quantity="10",
            expiry_date=(today - timedelta(days=3)).isoformat(),
        )
        assert opened.status_code == 201, opened.text
        batch_id = opened.json()["expiry_batches"][0]["id"]

        written = await client.post(
            f"/inventory/expiry/{batch_id}/write-off",
            params={"store_id": store_id},
            headers=headers,
            json={"quantity": "6", "reason": "expired on shelf"},
        )
        assert written.status_code == 200, written.text
        assert written.json()["quantity"] == "4.000"
        assert written.json()["status"] == "expired"

        detail = await client.get(f"/inventory/stock/{product['id']}", params={"store_id": store_id}, headers=headers)
        assert detail.json()["quantity"] == "4.000"

        movements = await client.get("/inventory/movements", params={"store_id": store_id}, headers=headers)
        items = movements.json()["items"]
        write_offs = [m for m in items if m["movement_type"] == "WRITE_OFF"]
        assert len(write_offs) == 1
        assert write_offs[0]["quantity_delta"] == "-6.000"
        assert write_offs[0]["resulting_quantity"] == "4.000"
        assert write_offs[0]["reference_type"] == "EXPIRY_BATCH"
        assert write_offs[0]["reference_id"] == batch_id

        full = await client.post(
            f"/inventory/expiry/{batch_id}/write-off",
            params={"store_id": store_id},
            headers=headers,
            json={"quantity": "4", "reason": "disposed"},
        )
        assert full.status_code == 200
        assert full.json()["quantity"] == "0.000"

        deleted = await client.delete(f"/inventory/expiry/{batch_id}", params={"store_id": store_id}, headers=headers)
        assert deleted.status_code == 200


async def test_write_off_validation(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    today = today_utc()
    async with client:
        product = await _create_product(client, headers, store_id)
        await _open_stock(
            client,
            headers,
            store_id,
            product["id"],
            quantity="10",
            expiry_date=(today + timedelta(days=60)).isoformat(),
        )
        detail = await client.get(f"/inventory/stock/{product['id']}", params={"store_id": store_id}, headers=headers)
        future_batch = detail.json()["expiry_batches"][0]["id"]

        expired = await client.post(
            "/inventory/expiry",
            params={"store_id": store_id},
            headers=headers,
            json={
                "product_id": product["id"],
                "quantity": "5",
                "expiry_date": (today - timedelta(days=1)).isoformat(),
            },
        )
        assert expired.status_code == 201
        batch_id = expired.json()["id"]

        not_expired = await client.post(
            f"/inventory/expiry/{future_batch}/write-off",
            params={"store_id": store_id},
            headers=headers,
            json={"quantity": "1", "reason": "too early"},
        )
        assert not_expired.status_code == 422

        too_much = await client.post(
            f"/inventory/expiry/{batch_id}/write-off",
            params={"store_id": store_id},
            headers=headers,
            json={"quantity": "6", "reason": "over"},
        )
        assert too_much.status_code == 422

        zero = await client.post(
            f"/inventory/expiry/{batch_id}/write-off",
            params={"store_id": store_id},
            headers=headers,
            json={"quantity": "0", "reason": "no-op"},
        )
        assert zero.status_code == 422

        no_reason = await client.post(
            f"/inventory/expiry/{batch_id}/write-off",
            params={"store_id": store_id},
            headers=headers,
            json={"quantity": "1", "reason": "   "},
        )
        assert no_reason.status_code == 422

        partial = await client.post(
            f"/inventory/expiry/{batch_id}/write-off",
            params={"store_id": store_id},
            headers=headers,
            json={"quantity": "2", "reason": "stale units"},
        )
        assert partial.status_code == 200
        assert partial.json()["quantity"] == "3.000"

        overdraft = await client.post(
            f"/inventory/expiry/{batch_id}/write-off",
            params={"store_id": store_id},
            headers=headers,
            json={"quantity": "4", "reason": "over"},
        )
        assert overdraft.status_code == 422


async def test_write_off_cross_store_isolation(tenant_creds):
    async with SessionLocal() as db:
        other = Store(tenant_id=tenant_creds["tenant_id"], name="Uptown")
        db.add(other)
        await db.flush()
        other_store_id = str(other.id)
        await db.commit()

    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    today = today_utc()
    async with client:
        product = await _create_product(client, headers, store_id)
        opened = await _open_stock(
            client,
            headers,
            store_id,
            product["id"],
            quantity="10",
            expiry_date=(today - timedelta(days=1)).isoformat(),
        )
        batch_id = opened.json()["expiry_batches"][0]["id"]

        resp = await client.post(
            f"/inventory/expiry/{batch_id}/write-off",
            params={"store_id": other_store_id},
            headers=headers,
            json={"quantity": "1", "reason": "sneaky"},
        )
    assert resp.status_code == 404
    assert resp.json()["detail"]["code"] == "NOT_FOUND"


# ── Stock list / summary ───────────────────────────────────────────────────


async def test_stock_list_and_summary(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    today = today_utc()
    async with client:
        low = await _create_product(client, headers, store_id, name="Butter", sku="BUT-1")
        out = await _create_product(client, headers, store_id, name="Cheese", sku="CHZ-1", barcode="4000000000001")
        healthy = await _create_product(client, headers, store_id, name="Eggs", sku="EGG-1", barcode="4000000000002")

        await _open_stock(client, headers, store_id, low["id"], quantity="2")
        await _open_stock(
            client, headers, store_id, healthy["id"], quantity="50", expiry_date=(today + timedelta(days=5)).isoformat()
        )

        listed = await client.get("/inventory/stock", params={"store_id": store_id}, headers=headers)
        assert listed.status_code == 200
        items = {it["product_id"]: it for it in listed.json()["items"]}
        assert items[low["id"]]["stock_status"] == "low_stock"
        assert items[out["id"]]["stock_status"] == "out_of_stock"
        assert items[healthy["id"]]["stock_status"] == "healthy"
        assert items[healthy["id"]]["nearest_expiry_status"] == "near_expiry"

        filtered = await client.get(
            "/inventory/stock", params={"store_id": store_id, "stock_status": "low_stock"}, headers=headers
        )
        assert [it["product_id"] for it in filtered.json()["items"]] == [low["id"]]

        summary = await client.get("/inventory/stock/summary", params={"store_id": store_id}, headers=headers)
        body = summary.json()
        assert body["total_products"] == 3
        assert body["low_stock"] == 1
        assert body["out_of_stock"] == 1
        assert body["healthy"] == 1
        assert body["near_expiry"] == 1
        assert body["expired"] == 0
        assert float(body["total_value"]) == 2.0 * 2.1 + 50.0 * 2.1


async def test_stock_cross_store_isolation(tenant_creds):
    async with SessionLocal() as db:
        other = Store(tenant_id=tenant_creds["tenant_id"], name="Uptown")
        db.add(other)
        await db.flush()
        other_store_id = str(other.id)
        cashier_email = f"cashier-{uuid.uuid4().hex[:8]}@test.dev"
        cashier = User(
            tenant_id=tenant_creds["tenant_id"],
            email=cashier_email,
            name="Cashier",
            password_hash=hash_password("Passw0rd!"),
        )
        db.add(cashier)
        admin_role = (await db.execute(select(Role).where(Role.tenant_id.is_(None), Role.name == "admin"))).scalar_one()
        db.add(UserRole(user_id=cashier.id, role_id=admin_role.id, store_id=tenant_creds["store_id"]))
        await db.commit()

    # ensure the product belongs to the *other* store so cross-store reads 404
    client, headers = await _authed_client(tenant_creds)
    async with client:
        product = await _create_product(client, headers, other_store_id)
        await _open_stock(client, headers, other_store_id, product["id"], quantity="7")

    resp = await login({"email": cashier_email, "password": "Passw0rd!"})
    token = resp.json()["access_token"]
    cashier_headers = {"Authorization": f"Bearer {token}"}
    async with await api_client() as client:
        own = await client.get(
            f"/inventory/stock/{product['id']}", params={"store_id": str(tenant_creds["store_id"])}, headers=cashier_headers
        )
        other_store_read = await client.get(
            f"/inventory/stock/{product['id']}", params={"store_id": other_store_id}, headers=cashier_headers
        )
    assert own.status_code == 404
    assert other_store_read.status_code == 404


# ── Barcode movement types (M4-B post-validation hardening) ────────────────


async def test_adjustment_sale_movement_type(tenant_creds):
    """Barcode Sale should produce a SALE movement, not ADJUSTMENT."""
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await _create_product(client, headers, store_id)
        await _open_stock(client, headers, store_id, product["id"], quantity="20")

        resp = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"delta": "-5", "reason": "AI Sale — barcode scan", "movement_type": "SALE"},
        )
        assert resp.status_code == 200, resp.text
        assert resp.json()["quantity"] == "15.000"

        movements = await client.get(
            "/inventory/movements",
            params={"store_id": store_id, "product_id": product["id"]},
            headers=headers,
        )
        items = movements.json()["items"]
        sale_movement = next(m for m in items if m["movement_type"] == "SALE")
        assert sale_movement["quantity_delta"] == "-5.000"
        assert sale_movement["resulting_quantity"] == "15.000"
        assert sale_movement["notes"] == "AI Sale — barcode scan"


async def test_adjustment_purchase_movement_type(tenant_creds):
    """Barcode Receive should produce a PURCHASE movement, not ADJUSTMENT."""
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await _create_product(client, headers, store_id)
        await _open_stock(client, headers, store_id, product["id"], quantity="10")

        resp = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"delta": "12", "reason": "AI Receive — barcode scan", "movement_type": "PURCHASE"},
        )
        assert resp.status_code == 200, resp.text
        assert resp.json()["quantity"] == "22.000"

        movements = await client.get(
            "/inventory/movements",
            params={"store_id": store_id, "product_id": product["id"]},
            headers=headers,
        )
        items = movements.json()["items"]
        purchase_movement = next(m for m in items if m["movement_type"] == "PURCHASE")
        assert purchase_movement["quantity_delta"] == "12.000"
        assert purchase_movement["resulting_quantity"] == "22.000"
        assert purchase_movement["notes"] == "AI Receive — barcode scan"


async def test_adjustment_default_movement_type_is_adjustment(tenant_creds):
    """Omitting movement_type must default to ADJUSTMENT (backwards compat)."""
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await _create_product(client, headers, store_id)
        await _open_stock(client, headers, store_id, product["id"], quantity="10")

        resp = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"delta": "-2", "reason": "waste"},
        )
        assert resp.status_code == 200, resp.text

        movements = await client.get(
            "/inventory/movements",
            params={"store_id": store_id, "product_id": product["id"]},
            headers=headers,
        )
        items = movements.json()["items"]
        waste_movement = next(m for m in items if m["notes"] == "waste")
        assert waste_movement["movement_type"] == "ADJUSTMENT"


async def test_adjustment_invalid_movement_type_rejected(tenant_creds):
    """Invalid movement_type must be rejected by Pydantic validation."""
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await _create_product(client, headers, store_id)
        await _open_stock(client, headers, store_id, product["id"], quantity="10")

        resp = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"delta": "-1", "reason": "bad type", "movement_type": "HACKED"},
        )
        assert resp.status_code == 422


async def test_sale_movement_stock_cannot_go_negative(tenant_creds):
    """SALE with delta exceeding stock must be rejected."""
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        product = await _create_product(client, headers, store_id)
        await _open_stock(client, headers, store_id, product["id"], quantity="3")

        resp = await client.patch(
            f"/inventory/stock/{product['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"delta": "-5", "reason": "AI Sale — barcode scan", "movement_type": "SALE"},
        )
        assert resp.status_code == 422
        assert resp.json()["detail"]["code"] == "VALIDATION_ERROR"
