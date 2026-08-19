import uuid

import httpx
import pytest
from httpx import ASGITransport
from sqlalchemy import delete, select

from app.core.db import SessionLocal, engine
from app.core.security import hash_password
from app.main import app
from app.models import Role, Store, Tenant, User, UserRole


@pytest.fixture(autouse=True)
async def _dispose_engine_after_test():
    yield
    await engine.dispose()


async def make_tenant(email: str, *, store_name: str = "Downtown", password: str = "Passw0rd!"):
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


async def cleanup_tenant(creds: dict) -> None:
    async with SessionLocal() as db:
        await db.execute(delete(User).where(User.tenant_id == creds["tenant_id"]))
        await db.execute(delete(Tenant).where(Tenant.id == creds["tenant_id"]))
        await db.commit()


@pytest.fixture
async def tenant_creds():
    creds = await make_tenant(f"owner-{uuid.uuid4().hex[:8]}@test.dev")
    yield creds
    await cleanup_tenant(creds)


async def api_client() -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


async def login(creds: dict, *, password: str | None = None, device: dict | None = None) -> httpx.Response:
    payload = {"email": creds["email"], "password": password or creds["password"]}
    if device is not None:
        payload["device"] = device
    async with await api_client() as client:
        return await client.post("/auth/login", json=payload)
