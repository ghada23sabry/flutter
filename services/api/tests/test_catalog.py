import uuid

from conftest import api_client, cleanup_tenant, login, make_tenant
from sqlalchemy import select

from app.core.db import SessionLocal
from app.core.security import hash_password
from app.models import AuditLog, Permission, Role, RolePermission, Store, User, UserRole


async def _authed_client(creds: dict):
    login_resp = await login(creds)
    assert login_resp.status_code == 200
    token = login_resp.json()["access_token"]
    return await api_client(), {"Authorization": f"Bearer {token}"}


def _category_payload(name: str = "Dairy", code: str | None = "DAIRY"):
    return {"name": name, "code": code}


def _product_payload(category_id: str | None = None, **overrides):
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
    if category_id:
        payload["category_id"] = category_id
    payload.update(overrides)
    return payload


async def _create_category(client, headers, store_id: str, **overrides):
    resp = await client.post("/categories", params={"store_id": store_id}, headers=headers, json=_category_payload(**overrides))
    assert resp.status_code == 201
    return resp.json()


async def _create_product(client, headers, store_id: str, **overrides):
    resp = await client.post("/products", params={"store_id": store_id}, headers=headers, json=_product_payload(**overrides))
    assert resp.status_code == 201
    return resp.json()


async def test_catalog_requires_auth(tenant_creds):
    async with await api_client() as client:
        resp = await client.get("/categories", params={"store_id": str(tenant_creds["store_id"])})
    assert resp.status_code == 401
    assert resp.json()["detail"]["code"] == "UNAUTHORIZED"


async def test_catalog_forbidden_without_permission(tenant_creds):
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
        role = Role(
            tenant_id=tenant_creds["tenant_id"],
            name="Cashier-Limited",
            description="test-only limited role",
            is_system=False,
        )
        db.add(role)
        await db.flush()
        sales_perm = (await db.execute(select(Permission).where(Permission.code == "sales.create"))).scalar_one()
        db.add(RolePermission(role_id=role.id, permission_id=sales_perm.id))
        db.add(UserRole(user_id=cashier.id, role_id=role.id, store_id=tenant_creds["store_id"]))
        await db.commit()

    resp = await login({"email": cashier_email, "password": "Passw0rd!"})
    assert resp.status_code == 200
    token = resp.json()["access_token"]
    async with await api_client() as client:
        listed = await client.get(
            "/categories", params={"store_id": str(tenant_creds["store_id"])}, headers={"Authorization": f"Bearer {token}"}
        )
        products = await client.get(
            "/products", params={"store_id": str(tenant_creds["store_id"])}, headers={"Authorization": f"Bearer {token}"}
        )
        suppliers = await client.get("/suppliers", headers={"Authorization": f"Bearer {token}"})
    assert listed.status_code == 403
    assert listed.json()["detail"]["code"] == "FORBIDDEN"
    assert products.status_code == 403
    assert suppliers.status_code == 403


async def test_category_crud_happy_path(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        created = await _create_category(client, headers, store_id)
        assert created["name"] == "Dairy"
        assert created["status"] == "active"

        listed = await client.get("/categories", params={"store_id": store_id}, headers=headers)
        assert listed.status_code == 200
        assert [c["id"] for c in listed.json()] == [created["id"]]

        updated = await client.patch(
            f"/categories/{created['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"name": "Dairy & Chilled", "status": "inactive"},
        )
        assert updated.status_code == 200
        assert updated.json()["name"] == "Dairy & Chilled"
        assert updated.json()["status"] == "inactive"

        filtered = await client.get("/categories", params={"store_id": store_id, "status": "active"}, headers=headers)
        assert filtered.json() == []


async def test_category_duplicate_code_conflict(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        await _create_category(client, headers, store_id, name="Dairy", code="DAIRY")
        dup = await client.post(
            "/categories", params={"store_id": store_id}, headers=headers, json=_category_payload(name="Milk", code="dairy")
        )
    assert dup.status_code == 409
    assert dup.json()["detail"]["code"] == "CONFLICT"


async def test_category_blank_name_rejected(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await client.post(
            "/categories",
            params={"store_id": str(tenant_creds["store_id"])},
            headers=headers,
            json=_category_payload(name="   "),
        )
    assert resp.status_code == 422


async def test_category_self_parent_rejected(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        created = await _create_category(client, headers, store_id)
        resp = await client.patch(
            f"/categories/{created['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"parent_id": created["id"]},
        )
    assert resp.status_code == 422


async def test_product_crud_lookup_and_search(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        category = await _create_category(client, headers, store_id)
        created = await _create_product(client, headers, store_id, category_id=category["id"])
        assert created["category_name"] == "Dairy"
        assert created["barcode"] == "5901234123457"
        assert created["status"] == "active"

        got = await client.get(f"/products/{created['id']}", params={"store_id": store_id}, headers=headers)
        assert got.status_code == 200
        assert got.json()["category_name"] == "Dairy"

        by_sku = await client.get(f"/products/lookup/sku/{created['sku']}", params={"store_id": store_id}, headers=headers)
        assert by_sku.status_code == 200
        assert by_sku.json()["id"] == created["id"]

        by_barcode = await client.get(
            f"/products/lookup/barcode/{created['barcode']}", params={"store_id": store_id}, headers=headers
        )
        assert by_barcode.status_code == 200
        assert by_barcode.json()["id"] == created["id"]

        searched = await client.get("/products", params={"store_id": store_id, "q": "milk"}, headers=headers)
        assert searched.status_code == 200
        assert [p["id"] for p in searched.json()["items"]] == [created["id"]]

        paged = await client.get("/products", params={"store_id": store_id, "page": 1, "page_size": 1}, headers=headers)
        body = paged.json()
        assert len(body["items"]) == 1
        assert body["total"] >= 1
        assert body["pages"] >= body["total"]

        updated = await client.patch(
            f"/products/{created['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"selling_price": "4.20"},
        )
        assert updated.status_code == 200
        assert updated.json()["selling_price"] == "4.20"


async def test_product_duplicate_sku_conflict(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        await _create_product(client, headers, store_id)
        dup = await client.post(
            "/products", params={"store_id": store_id}, headers=headers, json=_product_payload(name="Milk 2L", sku="milk-1l")
        )
    assert dup.status_code == 409
    assert dup.json()["detail"]["code"] == "CONFLICT"


async def test_product_barcode_normalized(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        created = await _create_product(client, headers, store_id, barcode="  ab-12x ")
        assert created["barcode"] == "AB-12X"
        by_barcode = await client.get(
            "/products/lookup/barcode/ab-12x", params={"store_id": store_id}, headers=headers
        )
        assert by_barcode.status_code == 200
        assert by_barcode.json()["id"] == created["id"]


async def test_product_duplicate_barcode_conflict(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        await _create_product(client, headers, store_id)
        dup = await client.post(
            "/products",
            params={"store_id": store_id},
            headers=headers,
            json=_product_payload(name="Milk 2L", sku="MILK-2L", barcode=" 5901234123457 "),
        )
    assert dup.status_code == 409
    assert dup.json()["detail"]["code"] == "CONFLICT"


async def test_product_duplicate_barcode_across_stores_allowed(tenant_creds):
    async with SessionLocal() as db:
        other = Store(tenant_id=tenant_creds["tenant_id"], name="Uptown")
        db.add(other)
        await db.flush()
        other_store_id = other.id
        await db.commit()

    client, headers = await _authed_client(tenant_creds)
    async with client:
        await _create_product(client, headers, str(tenant_creds["store_id"]))
        second = await _create_product(
            client,
            headers,
            str(other_store_id),
            name="Milk 2L",
            sku="MILK-2L",
            barcode="5901234123457",
        )
        assert second["barcode"] == "5901234123457"


async def test_product_update_audit_includes_barcode(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        created = await _create_product(client, headers, store_id, barcode="5901234123457")
        updated = await client.patch(
            f"/products/{created['id']}",
            params={"store_id": store_id},
            headers=headers,
            json={"barcode": "5901234123458"},
        )
        assert updated.status_code == 200
        assert updated.json()["barcode"] == "5901234123458"
    async with SessionLocal() as db:
        rows = (
            await db.execute(
                select(AuditLog).where(
                    AuditLog.action == "product_updated",
                    AuditLog.entity_id == created["id"],
                )
            )
        ).scalars().all()
        assert len(rows) == 1
        assert rows[0].before["barcode"] == "5901234123457"
        assert rows[0].after["barcode"] == "5901234123458"


async def test_supplier_crud_and_link(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    store_id = str(tenant_creds["store_id"])
    async with client:
        created = await client.post("/suppliers", headers=headers, json={"name": "Acme Foods", "phone": "555-0100"})
        assert created.status_code == 201
        supplier = created.json()

        listed = await client.get("/suppliers", headers=headers)
        assert listed.status_code == 200
        assert listed.json()["total"] >= 1

        product = await _create_product(client, headers, store_id)
        linked = await client.post(
            f"/suppliers/{supplier['id']}/products",
            params={"store_id": store_id},
            headers=headers,
            json={"product_id": product["id"], "supplier_sku": "ACM-01", "is_preferred": True},
        )
        assert linked.status_code == 201
        assert linked.json()["product_name"] == "Milk 1L"
        assert linked.json()["is_preferred"] is True

        supplier_products = await client.get(f"/suppliers/{supplier['id']}/products", headers=headers)
        assert supplier_products.status_code == 200
        assert supplier_products.json()[0]["product_sku"] == "MILK-1L"

        product_suppliers = await client.get(f"/products/{product['id']}/suppliers", params={"store_id": store_id}, headers=headers)
        assert product_suppliers.status_code == 200
        assert product_suppliers.json()[0]["supplier_name"] == "Acme Foods"

        dup = await client.post(
            f"/suppliers/{supplier['id']}/products",
            params={"store_id": store_id},
            headers=headers,
            json={"product_id": product["id"]},
        )
        assert dup.status_code == 409

        unlinked = await client.delete(
            f"/suppliers/{supplier['id']}/products/{product['id']}", params={"store_id": store_id}, headers=headers
        )
        assert unlinked.status_code == 200
        assert unlinked.json()["status"] == "ok"


async def test_cross_tenant_category_isolation():
    tenant_a = await make_tenant(f"owner-a-{uuid.uuid4().hex[:8]}@test.dev")
    tenant_b = await make_tenant(f"owner-b-{uuid.uuid4().hex[:8]}@test.dev")
    try:
        client_a, headers_a = await _authed_client(tenant_a)
        client_b, headers_b = await _authed_client(tenant_b)
        async with client_a:
            category_a = await _create_category(client_a, headers_a, str(tenant_a["store_id"]))
        async with client_b:
            got = await client_b.get(
                f"/categories/{category_a['id']}", params={"store_id": str(tenant_b["store_id"])}, headers=headers_b
            )
            patched = await client_b.patch(
                f"/categories/{category_a['id']}",
                params={"store_id": str(tenant_b["store_id"])},
                headers=headers_b,
                json={"name": "Nope"},
            )
        assert got.status_code == 404
        assert got.json()["detail"]["code"] == "NOT_FOUND"
        assert patched.status_code == 404
    finally:
        await cleanup_tenant(tenant_a)
        await cleanup_tenant(tenant_b)


async def test_cross_store_product_isolation(tenant_creds):
    async with SessionLocal() as db:
        other = Store(tenant_id=tenant_creds["tenant_id"], name="Uptown")
        db.add(other)
        await db.flush()
        other_store_id = other.id
        cashier_email = f"cashier-{uuid.uuid4().hex[:8]}@test.dev"
        cashier = User(
            tenant_id=tenant_creds["tenant_id"],
            email=cashier_email,
            name="Cashier",
            password_hash=hash_password("Passw0rd!"),
        )
        db.add(cashier)
        await db.flush()
        admin_role = (await db.execute(select(Role).where(Role.tenant_id.is_(None), Role.name == "admin"))).scalar_one()
        db.add(UserRole(user_id=cashier.id, role_id=admin_role.id, store_id=tenant_creds["store_id"]))
        await db.commit()

    resp = await login({"email": cashier_email, "password": "Passw0rd!"})
    assert resp.status_code == 200
    token = resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    async with await api_client() as client:
        own = await client.get("/products", params={"store_id": str(tenant_creds["store_id"])}, headers=headers)
        other_store = await client.get("/products", params={"store_id": str(other_store_id)}, headers=headers)
        create_other = await client.post(
            "/products", params={"store_id": str(other_store_id)}, headers=headers, json=_product_payload()
        )
    assert own.status_code == 200
    assert other_store.status_code == 404
    assert create_other.status_code == 404
