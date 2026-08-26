"""M4-A.5 — HTTP API for the AI scan domain (RBAC + integration).

Covers the required HTTP contract end-to-end:
401 unauthenticated, valid flow, revoked device, per-permission 403s
(ai.scan / ai.view / ai.reconcile / ai.confirm), cross-tenant/store 404,
invalid shelf 404, create/process, results + reconciliation retrieval,
confirmation, duplicate/FAILED/CANCELLED confirmation 409, NEEDS_REVIEW
confirmation requiring ai.confirm, no inventory mutation during process,
COUNT movement + audit after confirmation, and the image-size boundary.
"""

import uuid

from conftest import cleanup_tenant, login, make_tenant
from sqlalchemy import select
from test_confirm_scan import _audit_rows, _count_movements, _session_status
from test_scan_service import (
    BARCODE_A,
    BARCODE_B,
    FakeVisionPort,
    _authed_client,
    _barcode_item,
    _inventory,
    _movement_count,
    _scan_env,
)

from app.ai.mock_vision import MockImagePayload, encode_mock_image
from app.core.db import SessionLocal
from app.core.security import hash_password
from app.main import app
from app.models import Permission, Role, RolePermission, ScanSession, User, UserRole
from app.routers.ai import get_vision_port_dependency
from app.services.ai_service import SESSION_STATUS_NEEDS_REVIEW


async def _restricted_user(creds: dict, *, permissions: list[str], store_id=None) -> dict:
    """A user in the same tenant with exactly the granted permission codes,
    store-scoped to `store_id` (defaults to the tenant's store)."""
    async with SessionLocal() as db:
        email = f"restricted-{uuid.uuid4().hex[:8]}@test.dev"
        user = User(
            tenant_id=creds["tenant_id"],
            email=email,
            name="Restricted",
            password_hash=hash_password("Passw0rd!"),
            status="active",
        )
        db.add(user)
        await db.flush()
        role = Role(
            tenant_id=creds["tenant_id"],
            name=f"Restricted-{uuid.uuid4().hex[:6]}",
            description="test-only role",
            is_system=False,
        )
        db.add(role)
        await db.flush()
        for code in permissions:
            perm = (await db.execute(select(Permission).where(Permission.code == code))).scalar_one()
            db.add(RolePermission(role_id=role.id, permission_id=perm.id))
        db.add(UserRole(user_id=user.id, role_id=role.id, store_id=store_id or creds["store_id"]))
        await db.commit()
        return {"email": email, "password": "Passw0rd!", "user_id": user.id}


def _image(*items):
    return encode_mock_image(MockImagePayload(items=list(items)))


async def _create_scan(client, headers, creds, **body):
    return await client.post(
        "/ai/scans",
        params={"store_id": str(creds["store_id"])},
        headers=headers,
        json=body,
    )


async def _process_scan(client, headers, creds, session_id, content=b"mock-image-bytes"):
    return await client.post(
        f"/ai/scans/{session_id}/process",
        params={"store_id": str(creds["store_id"])},
        headers=headers,
        content=content,
    )


async def _confirm_scan(client, headers, creds, session_id):
    return await client.post(
        f"/ai/scans/{session_id}/confirm",
        params={"store_id": str(creds["store_id"])},
        headers=headers,
    )


# ── 1. Unauthenticated → 401 ────────────────────────────────────────────────


async def test_unauthenticated_401(tenant_creds):
    client, _ = await _authed_client(tenant_creds)
    async with client:
        create = await client.post(
            "/ai/scans", params={"store_id": str(tenant_creds["store_id"])}, json={}
        )
        get = await client.get(
            f"/ai/scans/{uuid.uuid4()}", params={"store_id": str(tenant_creds["store_id"])}
        )
        confirm = await client.post(
            f"/ai/scans/{uuid.uuid4()}/confirm",
            params={"store_id": str(tenant_creds["store_id"])},
        )
    assert create.status_code == 401
    assert create.json()["detail"]["code"] == "UNAUTHORIZED"
    assert get.status_code == 401
    assert confirm.status_code == 401


# ── 2. Valid authenticated request ──────────────────────────────────────────


async def test_valid_authenticated_create_201(tenant_creds):
    env = await _scan_env(tenant_creds)
    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _create_scan(client, headers, tenant_creds, shelf_id=str(env["shelf_id"]), note="morning")
        assert resp.status_code == 201, resp.text
    body = resp.json()
    assert body["store_id"] == str(tenant_creds["store_id"])
    assert body["shelf_id"] == str(env["shelf_id"])
    assert body["status"] == "processing"
    assert body["note"] == "morning"


# ── 3. Inactive/revoked device → existing auth failure ──────────────────────


async def test_revoked_device_fails_auth(tenant_creds):
    login_resp = await login(tenant_creds, device={"device_uuid": "ai-pos-0001", "platform": "android"})
    assert login_resp.status_code == 200
    token = login_resp.json()["access_token"]
    device_id = login_resp.json()["device"]["id"]

    async with SessionLocal() as db:
        from app.models import Device

        device = await db.get(Device, device_id)
        device.status = "revoked"
        await db.commit()

    client, _ = await _authed_client(tenant_creds)
    async with client:
        resp = await _create_scan(client, {"Authorization": f"Bearer {token}"}, tenant_creds)
    assert resp.status_code == 401
    assert resp.json()["detail"]["code"] == "DEVICE_REVOKED"


# ── 4-7. Missing permissions → 403 ──────────────────────────────────────────


async def test_missing_scan_permission_403(tenant_creds):
    restricted = await _restricted_user(tenant_creds, permissions=["sales.create"])
    client, _ = await _authed_client(tenant_creds)
    async with client:
        login_resp = await login({"email": restricted["email"], "password": restricted["password"]})
        assert login_resp.status_code == 200
        resp = await _create_scan(client, {"Authorization": f"Bearer {login_resp.json()['access_token']}"}, tenant_creds)
    assert resp.status_code == 403
    assert resp.json()["detail"]["code"] == "FORBIDDEN"


async def test_missing_view_permission_403(tenant_creds):
    restricted = await _restricted_user(tenant_creds, permissions=["sales.create"])
    login_resp = await login({"email": restricted["email"], "password": restricted["password"]})
    assert login_resp.status_code == 200
    client, _ = await _authed_client(tenant_creds)
    async with client:
        resp = await client.get(
            f"/ai/scans/{uuid.uuid4()}",
            params={"store_id": str(tenant_creds["store_id"])},
            headers={"Authorization": f"Bearer {login_resp.json()['access_token']}"},
        )
    assert resp.status_code == 403
    assert resp.json()["detail"]["code"] == "FORBIDDEN"


async def test_missing_reconcile_permission_403(tenant_creds):
    restricted = await _restricted_user(tenant_creds, permissions=["sales.create"])
    login_resp = await login({"email": restricted["email"], "password": restricted["password"]})
    assert login_resp.status_code == 200
    client, _ = await _authed_client(tenant_creds)
    async with client:
        resp = await client.get(
            f"/ai/scans/{uuid.uuid4()}/reconciliations",
            params={"store_id": str(tenant_creds["store_id"])},
            headers={"Authorization": f"Bearer {login_resp.json()['access_token']}"},
        )
    assert resp.status_code == 403
    assert resp.json()["detail"]["code"] == "FORBIDDEN"


async def test_missing_confirm_permission_403(tenant_creds):
    restricted = await _restricted_user(tenant_creds, permissions=["sales.create"])
    login_resp = await login({"email": restricted["email"], "password": restricted["password"]})
    assert login_resp.status_code == 200
    client, _ = await _authed_client(tenant_creds)
    async with client:
        resp = await _confirm_scan(
            client,
            {"Authorization": f"Bearer {login_resp.json()['access_token']}"},
            tenant_creds,
            uuid.uuid4(),
        )
    assert resp.status_code == 403
    assert resp.json()["detail"]["code"] == "FORBIDDEN"


# ── 8. Cross-tenant scan → 404 ──────────────────────────────────────────────


async def test_cross_tenant_scan_404():
    tenant_a = await make_tenant(f"owner-a-{uuid.uuid4().hex[:8]}@test.dev")
    tenant_b = await make_tenant(f"owner-b-{uuid.uuid4().hex[:8]}@test.dev")
    try:
        client, headers = await _authed_client(tenant_a)
        async with client:
            resp = await _create_scan(
                client, headers, {"store_id": tenant_b["store_id"], "tenant_id": tenant_a["tenant_id"]}
            )
        assert resp.status_code == 404
        assert resp.json()["detail"]["code"] == "NOT_FOUND"
    finally:
        await cleanup_tenant(tenant_a)
        await cleanup_tenant(tenant_b)


# ── 9. Cross-store scan → 404 ───────────────────────────────────────────────


async def test_cross_store_scan_404(tenant_creds):
    async with SessionLocal() as db:
        from app.models import Store

        other = Store(tenant_id=tenant_creds["tenant_id"], name="North")
        db.add(other)
        await db.commit()
        await db.refresh(other)
        other_store_id = other.id

    restricted = await _restricted_user(tenant_creds, permissions=["ai.scan"])
    login_resp = await login({"email": restricted["email"], "password": restricted["password"]})
    assert login_resp.status_code == 200
    client, _ = await _authed_client(tenant_creds)
    async with client:
        resp = await client.post(
            "/ai/scans",
            params={"store_id": str(other_store_id)},
            headers={"Authorization": f"Bearer {login_resp.json()['access_token']}"},
            json={},
        )
    assert resp.status_code == 404
    assert resp.json()["detail"]["code"] == "NOT_FOUND"


# ── 10. Invalid shelf → 404 ─────────────────────────────────────────────────


async def test_invalid_shelf_404():
    tenant_a = await make_tenant(f"owner-a-{uuid.uuid4().hex[:8]}@test.dev")
    tenant_b = await make_tenant(f"owner-b-{uuid.uuid4().hex[:8]}@test.dev")
    try:
        env_b = await _scan_env(tenant_b)
        client, headers = await _authed_client(tenant_a)
        async with client:
            resp = await _create_scan(
                client, headers, tenant_a, shelf_id=str(env_b["shelf_id"])
            )
        assert resp.status_code == 404
        assert resp.json()["detail"]["code"] == "NOT_FOUND"
    finally:
        await cleanup_tenant(tenant_a)
        await cleanup_tenant(tenant_b)


# ── 11. Successful create/process ───────────────────────────────────────────


async def test_successful_create_process(tenant_creds):
    env = await _scan_env(tenant_creds)
    client, headers = await _authed_client(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_B, 2)])
    app.dependency_overrides[get_vision_port_dependency] = lambda: port
    try:
        async with client:
            created = await _create_scan(client, headers, tenant_creds, shelf_id=str(env["shelf_id"]))
            assert created.status_code == 201, created.text
            session_id = created.json()["id"]
            processed = await _process_scan(
                client,
                headers,
                tenant_creds,
                session_id,
                content=_image(_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_B, 2)),
            )
            assert processed.status_code == 200, processed.text
    finally:
        app.dependency_overrides.pop(get_vision_port_dependency, None)
    body = processed.json()
    assert body["id"] == session_id
    assert body["status"] == "completed"
    assert body["image_count"] == 1


# ── 12. Successful results retrieval ────────────────────────────────────────


async def test_results_retrieval(tenant_creds):
    env = await _scan_env(tenant_creds)
    client, headers = await _authed_client(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_B, 2)])
    app.dependency_overrides[get_vision_port_dependency] = lambda: port
    try:
        async with client:
            created = await _create_scan(client, headers, tenant_creds)
            session_id = created.json()["id"]
            await _process_scan(
                client,
                headers,
                tenant_creds,
                session_id,
                content=_image(_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_B, 2)),
            )
            status = await client.get(
                f"/ai/scans/{session_id}", params={"store_id": str(tenant_creds["store_id"])}, headers=headers
            )
            dets = await client.get(
                f"/ai/scans/{session_id}/detections",
                params={"store_id": str(tenant_creds["store_id"])},
                headers=headers,
            )
    finally:
        app.dependency_overrides.pop(get_vision_port_dependency, None)
    assert status.status_code == 200
    assert status.json()["status"] == "completed"
    assert dets.status_code == 200
    detections = dets.json()
    assert len(detections) == 2
    assert {d["product_id"] for d in detections} == {str(env["product_a"]), str(env["product_b"])}
    assert {d["method"] for d in detections} == {"barcode"}


# ── 13. Successful reconciliation retrieval ─────────────────────────────────


async def test_reconciliation_retrieval(tenant_creds):
    env = await _scan_env(tenant_creds)
    client, headers = await _authed_client(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_B, 2)])
    app.dependency_overrides[get_vision_port_dependency] = lambda: port
    try:
        async with client:
            created = await _create_scan(client, headers, tenant_creds)
            session_id = created.json()["id"]
            await _process_scan(
                client,
                headers,
                tenant_creds,
                session_id,
                content=_image(_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_B, 2)),
            )
            resp = await client.get(
                f"/ai/scans/{session_id}/reconciliations",
                params={"store_id": str(tenant_creds["store_id"])},
                headers=headers,
            )
    finally:
        app.dependency_overrides.pop(get_vision_port_dependency, None)
    assert resp.status_code == 200
    recs = resp.json()
    assert len(recs) == 2
    by_product = {r["product_id"]: r for r in recs}
    a = by_product[str(env["product_a"])]
    assert a["product_name"] == "Milk 1L"
    assert a["sku"] == "MILK-1L"
    assert a["system_quantity"] == "10.000"
    assert a["detected_quantity"] == "3.000"
    assert a["variance"] == "-7.000"
    assert a["status"] == "needs_review"


# ── 14. Successful confirmation ─────────────────────────────────────────────


async def test_successful_confirmation(tenant_creds):
    env = await _scan_env(tenant_creds)
    client, headers = await _authed_client(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_B, 2)])
    app.dependency_overrides[get_vision_port_dependency] = lambda: port
    try:
        async with client:
            created = await _create_scan(client, headers, tenant_creds)
            session_id = created.json()["id"]
            await _process_scan(
                client,
                headers,
                tenant_creds,
                session_id,
                content=_image(_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_B, 2)),
            )
            confirmed = await _confirm_scan(client, headers, tenant_creds, session_id)
    finally:
        app.dependency_overrides.pop(get_vision_port_dependency, None)
    assert confirmed.status_code == 200, confirmed.text
    assert confirmed.json()["status"] == "confirmed"

    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == 3
    assert await _inventory(tenant_creds["store_id"], env["product_b"]) == 2


# ── 15. Duplicate confirmation → 409 ────────────────────────────────────────


async def test_duplicate_confirmation_409(tenant_creds):
    env = await _scan_env(tenant_creds)
    client, headers = await _authed_client(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 4)])
    app.dependency_overrides[get_vision_port_dependency] = lambda: port
    try:
        async with client:
            created = await _create_scan(client, headers, tenant_creds)
            session_id = created.json()["id"]
            await _process_scan(
                client,
                headers,
                tenant_creds,
                session_id,
                content=_image(_barcode_item(BARCODE_A, 4)),
            )
            first = await _confirm_scan(client, headers, tenant_creds, session_id)
            second = await _confirm_scan(client, headers, tenant_creds, session_id)
    finally:
        app.dependency_overrides.pop(get_vision_port_dependency, None)
    assert first.status_code == 200
    assert second.status_code == 409
    assert second.json()["detail"]["code"] == "CONFLICT"
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == 4
    assert len(await _count_movements(tenant_creds["store_id"], session_id)) == 1


# ── 16. FAILED scan confirmation → 409 ──────────────────────────────────────


async def test_failed_scan_confirmation_409(tenant_creds):
    env = await _scan_env(tenant_creds)
    client, headers = await _authed_client(tenant_creds)
    port = FakeVisionPort(raise_error=True)
    app.dependency_overrides[get_vision_port_dependency] = lambda: port
    try:
        async with client:
            created = await _create_scan(client, headers, tenant_creds)
            session_id = created.json()["id"]
            valid_image = _image(_barcode_item(BARCODE_A, 3))
            processed = await _process_scan(client, headers, tenant_creds, session_id, content=valid_image)
            assert processed.status_code == 500, processed.text
            assert processed.json()["detail"]["code"] == "INTERNAL_ERROR"
            assert await _session_status(session_id) == "failed"
            confirmed = await _confirm_scan(client, headers, tenant_creds, session_id)
    finally:
        app.dependency_overrides.pop(get_vision_port_dependency, None)
    assert confirmed.status_code == 409
    assert confirmed.json()["detail"]["code"] == "CONFLICT"
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == 10
    assert await _count_movements(tenant_creds["store_id"], session_id) == []


# ── 17. CANCELLED scan confirmation → 409 ───────────────────────────────────


async def test_cancelled_scan_confirmation_409(tenant_creds):
    env = await _scan_env(tenant_creds)
    client, headers = await _authed_client(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 3)])
    app.dependency_overrides[get_vision_port_dependency] = lambda: port
    try:
        async with client:
            created = await _create_scan(client, headers, tenant_creds)
            session_id = created.json()["id"]
            await _process_scan(
                client,
                headers,
                tenant_creds,
                session_id,
                content=_image(_barcode_item(BARCODE_A, 3)),
            )
            async with SessionLocal() as db:
                row = (await db.execute(select(ScanSession).where(ScanSession.id == session_id))).scalar_one()
                row.status = "cancelled"
                await db.commit()
            confirmed = await _confirm_scan(client, headers, tenant_creds, session_id)
    finally:
        app.dependency_overrides.pop(get_vision_port_dependency, None)
    assert confirmed.status_code == 409
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == 10


# ── 18. NEEDS_REVIEW confirmation requires explicit confirm permission ──────


async def test_needs_review_confirmation_requires_confirm_permission(tenant_creds):
    env = await _scan_env(tenant_creds)
    client, headers = await _authed_client(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 3, confidence="0.50")])
    app.dependency_overrides[get_vision_port_dependency] = lambda: port
    try:
        async with client:
            created = await _create_scan(client, headers, tenant_creds)
            session_id = created.json()["id"]
            await _process_scan(
                client,
                headers,
                tenant_creds,
                session_id,
                content=_image(_barcode_item(BARCODE_A, 3, confidence="0.50")),
            )
            assert await _session_status(session_id) == SESSION_STATUS_NEEDS_REVIEW

            restricted = await _restricted_user(tenant_creds, permissions=["ai.view", "ai.reconcile"])
            restricted_login = await login({"email": restricted["email"], "password": restricted["password"]})
            assert restricted_login.status_code == 200
            denied = await _confirm_scan(
                client,
                {"Authorization": f"Bearer {restricted_login.json()['access_token']}"},
                tenant_creds,
                session_id,
            )
    finally:
        app.dependency_overrides.pop(get_vision_port_dependency, None)
    assert denied.status_code == 403
    assert denied.json()["detail"]["code"] == "FORBIDDEN"
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == 10
    assert await _count_movements(tenant_creds["store_id"], session_id) == []
    assert await _audit_rows(session_id) == []


# ── 19. No inventory mutation during process ────────────────────────────────


async def test_no_inventory_mutation_during_process(tenant_creds):
    env = await _scan_env(tenant_creds)
    store_id = tenant_creds["store_id"]
    moves_before = await _movement_count(store_id)
    client, headers = await _authed_client(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_B, 2)])
    app.dependency_overrides[get_vision_port_dependency] = lambda: port
    try:
        async with client:
            created = await _create_scan(client, headers, tenant_creds)
            session_id = created.json()["id"]
            processed = await _process_scan(
                client,
                headers,
                tenant_creds,
                session_id,
                content=_image(_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_B, 2)),
            )
    finally:
        app.dependency_overrides.pop(get_vision_port_dependency, None)
    assert processed.status_code == 200
    assert await _inventory(store_id, env["product_a"]) == 10
    assert await _inventory(store_id, env["product_b"]) == 10
    assert await _movement_count(store_id) == moves_before


# ── 20. COUNT movement after confirmation ───────────────────────────────────


async def test_count_movement_after_confirmation(tenant_creds):
    env = await _scan_env(tenant_creds)
    client, headers = await _authed_client(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 6), _barcode_item(BARCODE_B, 13)])
    app.dependency_overrides[get_vision_port_dependency] = lambda: port
    try:
        async with client:
            created = await _create_scan(client, headers, tenant_creds)
            session_id = created.json()["id"]
            await _process_scan(
                client,
                headers,
                tenant_creds,
                session_id,
                content=_image(_barcode_item(BARCODE_A, 6), _barcode_item(BARCODE_B, 13)),
            )
            confirmed = await _confirm_scan(client, headers, tenant_creds, session_id)
    finally:
        app.dependency_overrides.pop(get_vision_port_dependency, None)
    assert confirmed.status_code == 200

    by_product = {m.product_id: m for m in await _count_movements(tenant_creds["store_id"], session_id)}
    assert by_product[env["product_a"]].quantity_delta == -4
    assert by_product[env["product_a"]].resulting_quantity == 6
    assert by_product[env["product_b"]].quantity_delta == 3
    assert by_product[env["product_b"]].resulting_quantity == 13


# ── 21. Audit after confirmation ────────────────────────────────────────────


async def test_audit_after_confirmation(tenant_creds):
    env = await _scan_env(tenant_creds)
    client, headers = await _authed_client(tenant_creds)
    port = FakeVisionPort([_barcode_item(BARCODE_A, 3)])
    app.dependency_overrides[get_vision_port_dependency] = lambda: port
    try:
        async with client:
            created = await _create_scan(client, headers, tenant_creds)
            session_id = created.json()["id"]
            await _process_scan(
                client,
                headers,
                tenant_creds,
                session_id,
                content=_image(_barcode_item(BARCODE_A, 3)),
            )
            confirmed = await _confirm_scan(client, headers, tenant_creds, session_id)
    finally:
        app.dependency_overrides.pop(get_vision_port_dependency, None)
    assert confirmed.status_code == 200

    rows = await _audit_rows(session_id)
    assert len(rows) == 1
    assert rows[0].action == "scan_confirmed"
    assert rows[0].entity_type == "scan_session"
    assert rows[0].entity_id == str(session_id)
    assert rows[0].tenant_id == tenant_creds["tenant_id"]
    assert rows[0].store_id == tenant_creds["store_id"]
    assert env is not None


# ── Extra boundaries (beyond the required list) ─────────────────────────────


async def test_oversized_image_rejected_422(tenant_creds, monkeypatch):
    import app.routers.ai as ai_router

    monkeypatch.setattr(ai_router, "MAX_IMAGE_BYTES", 10)
    await _scan_env(tenant_creds)
    client, headers = await _authed_client(tenant_creds)
    async with client:
        created = await _create_scan(client, headers, tenant_creds)
        session_id = created.json()["id"]
        resp = await _process_scan(client, headers, tenant_creds, session_id, content=b"x" * 100)
    assert resp.status_code == 422
    assert resp.json()["detail"]["code"] == "VALIDATION_ERROR"
    assert await _session_status(session_id) == "processing"


async def test_process_unknown_session_404(tenant_creds):
    client, headers = await _authed_client(tenant_creds)
    async with client:
        valid_image = _image(_barcode_item(BARCODE_A, 1))
        resp = await _process_scan(client, headers, tenant_creds, uuid.uuid4(), content=valid_image)
    assert resp.status_code == 404
    assert resp.json()["detail"]["code"] == "NOT_FOUND"


async def test_view_cross_tenant_404():
    tenant_a = await make_tenant(f"owner-a-{uuid.uuid4().hex[:8]}@test.dev")
    tenant_b = await make_tenant(f"owner-b-{uuid.uuid4().hex[:8]}@test.dev")
    try:
        env_a = await _scan_env(tenant_a)
        client_a, headers_a = await _authed_client(tenant_a)
        async with client_a:
            created = await _create_scan(client_a, headers_a, tenant_a, shelf_id=str(env_a["shelf_id"]))
        session_id = created.json()["id"]

        client_b, headers_b = await _authed_client(tenant_b)
        async with client_b:
            resp = await client_b.get(
                f"/ai/scans/{session_id}",
                params={"store_id": str(tenant_a["store_id"])},
                headers=headers_b,
            )
        assert resp.status_code == 404
    finally:
        await cleanup_tenant(tenant_a)
        await cleanup_tenant(tenant_b)
