import uuid

import httpx
import pytest
from httpx import ASGITransport
from sqlalchemy import delete, select

from app.core.db import SessionLocal
from app.core.security import hash_password
from app.main import app
from app.models import Permission, Role, RolePermission, Store, Tenant, User, UserRole

OWNER_PERMISSIONS = {
    "inventory.view",
    "inventory.update",
    "inventory.adjust",
    "inventory.manage_layout",
    "inventory.view_movements",
    "inventory.manage_expiry",
    "products.view",
    "products.manage",
    "categories.view",
    "categories.manage",
    "suppliers.view",
    "suppliers.manage",
    "sales.view",
    "sales.create",
    "ai.view",
    "ai.scan",
    "ai.reconcile",
    "ai.confirm",
    "devices.view",
    "devices.revoke",
    "reports.view",
}


async def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def _make_tenant(email: str, *, store_name: str = "Downtown", password: str = "Passw0rd!"):
    async with SessionLocal() as db:
        slug = f"t-{uuid.uuid4().hex[:10]}"
        tenant = Tenant(name=email.split("@")[0], slug=slug)
        db.add(tenant)
        await db.flush()
        store = Store(tenant_id=tenant.id, name=store_name)
        db.add(store)
        await db.flush()
        user = User(
            tenant_id=tenant.id,
            email=email,
            name="Owner",
            password_hash=hash_password(password),
            status="active",
        )
        db.add(user)
        await db.flush()
        owner_role = (await db.execute(select(Role).where(Role.tenant_id.is_(None), Role.name == "owner"))).scalar_one()
        db.add(UserRole(user_id=user.id, role_id=owner_role.id, store_id=None))
        await db.commit()
        return {
            "email": email,
            "password": password,
            "tenant_id": tenant.id,
            "store_id": store.id,
            "user_id": user.id,
        }


async def _cleanup(creds: dict) -> None:
    async with SessionLocal() as db:
        await db.execute(delete(User).where(User.tenant_id == creds["tenant_id"]))
        await db.execute(delete(Tenant).where(Tenant.id == creds["tenant_id"]))
        await db.commit()


@pytest.fixture
async def tenant_creds():
    creds = await _make_tenant(f"owner-{uuid.uuid4().hex[:8]}@test.dev")
    yield creds
    await _cleanup(creds)


async def _login(creds: dict, *, password: str | None = None, device: dict | None = None) -> httpx.Response:
    payload = {"email": creds["email"], "password": password or creds["password"]}
    if device is not None:
        payload["device"] = device
    async with await _client() as client:
        return await client.post("/auth/login", json=payload)


async def test_login_success_with_device(tenant_creds):
    resp = await _login(tenant_creds, device={"device_uuid": "test-device-0001", "platform": "android"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["access_token"]
    assert body["refresh_token"]
    assert body["token_type"] == "bearer"
    assert body["user"]["email"] == tenant_creds["email"]
    assert body["user"]["status"] == "active"
    assert set(body["permissions"]) == OWNER_PERMISSIONS
    assert len(body["stores"]) == 1
    assert body["stores"][0]["name"] == "Downtown"
    assert body["device"] is not None
    assert body["device"]["device_uuid"] == "test-device-0001"


async def test_login_invalid_credentials(tenant_creds):
    resp = await _login(tenant_creds, password="WrongPass1!")
    assert resp.status_code == 401
    assert resp.json()["detail"]["code"] == "INVALID_CREDENTIALS"


async def test_login_disabled_account(tenant_creds):
    async with SessionLocal() as db:
        user = await db.get(User, tenant_creds["user_id"])
        user.status = "disabled"
        await db.commit()
    resp = await _login(tenant_creds)
    assert resp.status_code == 403
    assert resp.json()["detail"]["code"] == "ACCOUNT_DISABLED"


async def test_me_requires_auth():
    async with await _client() as client:
        resp = await client.get("/auth/me")
    assert resp.status_code == 401
    assert resp.json()["detail"]["code"] == "UNAUTHORIZED"


async def test_me_returns_identity(tenant_creds):
    login = await _login(tenant_creds, device={"device_uuid": "test-device-0002"})
    token = login.json()["access_token"]
    async with await _client() as client:
        resp = await client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["user"]["email"] == tenant_creds["email"]
    assert set(body["permissions"]) == OWNER_PERMISSIONS
    assert body["stores"][0]["id"] == str(tenant_creds["store_id"])
    assert body["device"]["device_uuid"] == "test-device-0002"


async def test_refresh_rotates_token(tenant_creds):
    login = await _login(tenant_creds)
    refresh_token = login.json()["refresh_token"]
    async with await _client() as client:
        resp = await client.post("/auth/refresh", json={"refresh_token": refresh_token})
        assert resp.status_code == 200
        body = resp.json()
        assert body["access_token"]
        new_refresh = body["refresh_token"]
        assert new_refresh != refresh_token
        reused = await client.post("/auth/refresh", json={"refresh_token": refresh_token})
    assert reused.status_code == 401
    assert reused.json()["detail"]["code"] == "UNAUTHORIZED"


async def test_logout_revokes_session(tenant_creds):
    login = await _login(tenant_creds)
    token = login.json()["access_token"]
    refresh_token = login.json()["refresh_token"]
    headers = {"Authorization": f"Bearer {token}"}
    async with await _client() as client:
        logout = await client.post("/auth/logout", headers=headers)
        assert logout.status_code == 200
        after = await client.get("/auth/me", headers=headers)
        refreshed = await client.post("/auth/refresh", json={"refresh_token": refresh_token})
    assert after.status_code == 401
    assert refreshed.status_code == 401


async def test_device_register_and_revoke_blocks_login(tenant_creds):
    login = await _login(tenant_creds)
    token = login.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    async with await _client() as client:
        reg = await client.post(
            "/devices/register",
            json={"store_id": str(tenant_creds["store_id"]), "device_uuid": "pos-2026-001", "name": "POS 1"},
            headers=headers,
        )
        assert reg.status_code == 201
        device_id = reg.json()["id"]
        listed = await client.get("/devices", headers=headers)
        revoke = await client.post(f"/devices/{device_id}/revoke", headers=headers)
    assert listed.status_code == 200
    assert any(d["id"] == device_id for d in listed.json())
    assert revoke.status_code == 200

    relogin = await _login(tenant_creds, device={"device_uuid": "pos-2026-001"})
    assert relogin.status_code == 401
    assert relogin.json()["detail"]["code"] == "DEVICE_REVOKED"


async def test_devices_list_requires_permission(tenant_creds):
    login = await _login(tenant_creds)
    token = login.json()["access_token"]
    async with await _client() as client:
        resp = await client.get("/devices", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200


async def test_cross_tenant_device_isolation():
    tenant_a = await _make_tenant(f"owner-a-{uuid.uuid4().hex[:8]}@test.dev")
    tenant_b = await _make_tenant(f"owner-b-{uuid.uuid4().hex[:8]}@test.dev")
    try:
        login_a = await _login(tenant_a, device={"device_uuid": "dev-a-0001"})
        login_b = await _login(tenant_b, device={"device_uuid": "dev-b-0001"})
        token_b = login_b.json()["access_token"]
        device_a_id = login_a.json()["device"]["id"]
        async with await _client() as client:
            resp = await client.post(
                f"/devices/{device_a_id}/revoke", headers={"Authorization": f"Bearer {token_b}"}
            )
        assert resp.status_code == 404
    finally:
        await _cleanup(tenant_a)
        await _cleanup(tenant_b)


async def test_users_me(tenant_creds):
    login = await _login(tenant_creds)
    token = login.json()["access_token"]
    async with await _client() as client:
        resp = await client.get("/users/me", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    assert resp.json()["email"] == tenant_creds["email"]


async def test_store_scoped_cashier_sees_only_own_store(tenant_creds):
    async with SessionLocal() as db:
        other = Store(tenant_id=tenant_creds["tenant_id"], name="Uptown")
        db.add(other)
        await db.flush()
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

    resp = await _login(
        {"email": cashier_email, "password": "Passw0rd!"},
        device={"device_uuid": "cashier-pos-1"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["stores"]) == 1
    assert body["stores"][0]["id"] == str(tenant_creds["store_id"])
    assert "devices.revoke" in body["permissions"]
    assert "products.manage" in body["permissions"]

    async with await _client() as client:
        listed = await client.get("/devices", headers={"Authorization": f"Bearer {body['access_token']}"})
    assert listed.status_code == 200
    assert all(d["store_id"] == str(tenant_creds["store_id"]) for d in listed.json())


async def test_cashier_without_permission_gets_403_on_owner_endpoint(tenant_creds):
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
        cashier_role = Role(
            tenant_id=tenant_creds["tenant_id"],
            name="Cashier-Restricted",
            description="test-only limited role",
            is_system=False,
        )
        db.add(cashier_role)
        await db.flush()
        sales_perm = (await db.execute(select(Permission).where(Permission.code == "sales.create"))).scalar_one()
        db.add(RolePermission(role_id=cashier_role.id, permission_id=sales_perm.id))
        db.add(UserRole(user_id=cashier.id, role_id=cashier_role.id, store_id=tenant_creds["store_id"]))
        await db.commit()

    resp = await _login({"email": cashier_email, "password": "Passw0rd!"})
    assert resp.status_code == 200
    token = resp.json()["access_token"]
    assert resp.json()["permissions"] == ["sales.create"]

    async with await _client() as client:
        listed = await client.get("/devices", headers={"Authorization": f"Bearer {token}"})
        revoke = await client.post(
            f"/devices/{uuid.uuid4()}/revoke", headers={"Authorization": f"Bearer {token}"}
        )
        me = await client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert listed.status_code == 403
    assert listed.json()["detail"]["code"] == "FORBIDDEN"
    assert revoke.status_code == 403
    assert me.status_code == 200
