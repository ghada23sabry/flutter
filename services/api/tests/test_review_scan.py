"""M4-A.6 — reconciliation review (PATCH) before explicit confirmation.

Covers the required review contract:
apply resolution, ignore resolution, manual quantity override, negative quantity
rejected, invalid resolution rejected, ai.reconcile permission 403, cross-tenant/
store 404, wrong scan↔reconciliation relationship 404, ignored reconciliation
does not mutate inventory, override becomes the COUNT target, double confirm
still 409, stale inventory still 409, rollback remains atomic, audit records the
review decision — plus closed-state rejection (processing/confirmed) and
ignore-with-quantity rejection.
"""

import uuid
from decimal import Decimal

from conftest import cleanup_tenant, login, make_tenant
from sqlalchemy import select
from test_ai_http import _confirm_scan, _restricted_user
from test_confirm_scan import _audit_rows, _confirm, _count_movements, _session_status
from test_scan_service import (
    BARCODE_A,
    BARCODE_B,
    FakeVisionPort,
    _authed_client,
    _barcode_item,
    _create,
    _inventory,
    _process,
    _reconciliations,
    _scan_env,
)

from app.core.db import SessionLocal
from app.models import AuditLog, Store
from app.services.ai_service import SESSION_STATUS_COMPLETED


async def _review(client, headers, creds, session_id, reconciliation_id, body):
    return await client.patch(
        f"/ai/scans/{session_id}/reconciliations/{reconciliation_id}",
        params={"store_id": str(creds["store_id"])},
        headers=headers,
        json=body,
    )


async def _reviewed_session(creds, items):
    """Create + process a scan and return (session, env, reconciliations)."""
    env = await _scan_env(creds)
    session = await _create(creds)
    await _process(creds, session.id, FakeVisionPort(list(items)))
    recs = await _reconciliations(session.id)
    return env, session, recs


# ── 1. Apply resolution ──────────────────────────────────────────────────────


async def test_apply_resolution(tenant_creds):
    env, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]
    assert rec.status == "needs_review"

    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(client, headers, tenant_creds, session.id, rec.id, {"resolution": "apply"})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["id"] == str(rec.id)
    assert body["resolution"] == "apply"
    assert Decimal(body["detected_quantity"]) == Decimal(3)
    assert body["product_name"] == "Milk 1L"
    assert body["sku"] == "MILK-1L"

    # Applying the existing detected quantity → confirm writes the count.
    await _confirm(tenant_creds, session.id)
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(3)


# ── 2. Ignore resolution ─────────────────────────────────────────────────────


async def test_ignore_resolution(tenant_creds):
    env, session, recs = await _reviewed_session(
        tenant_creds, [_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_B, 2)]
    )
    a = next(r for r in recs if r.product_id == env["product_a"])
    b = next(r for r in recs if r.product_id == env["product_b"])
    del b

    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(client, headers, tenant_creds, session.id, a.id, {"resolution": "ignore"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["resolution"] == "ignore"

    await _confirm(tenant_creds, session.id)
    # Ignored product A: no inventory change, no COUNT movement.
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(10)
    moves = await _count_movements(tenant_creds["store_id"], session.id)
    assert {m.product_id for m in moves} == {env["product_b"]}
    assert await _inventory(tenant_creds["store_id"], env["product_b"]) == Decimal(2)


# ── 3. Manual quantity override ──────────────────────────────────────────────


async def test_quantity_override(tenant_creds):
    _, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]

    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(
            client, headers, tenant_creds, session.id, rec.id, {"resolution": "apply", "detected_quantity": 12}
        )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["resolution"] == "apply"
    assert Decimal(body["detected_quantity"]) == Decimal(12)
    assert Decimal(body["variance"]) == Decimal(2)  # 12 - recorded system 10
    assert body["status"] == "needs_review"


# ── 4. Negative quantity rejected ────────────────────────────────────────────


async def test_negative_quantity_rejected(tenant_creds):
    _, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]

    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(
            client, headers, tenant_creds, session.id, rec.id, {"resolution": "apply", "detected_quantity": -1}
        )
    assert resp.status_code == 422
    assert resp.json()["detail"]["code"] == "VALIDATION_ERROR"


async def test_oversized_precision_quantity_rejected(tenant_creds):
    _, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]

    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(
            client, headers, tenant_creds, session.id, rec.id, {"resolution": "apply", "detected_quantity": "1.0001"}
        )
    assert resp.status_code == 422


async def test_non_numeric_quantity_rejected(tenant_creds):
    _, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]

    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(
            client, headers, tenant_creds, session.id, rec.id, {"resolution": "apply", "detected_quantity": "abc"}
        )
    assert resp.status_code == 422


# ── 5. Invalid resolution rejected ───────────────────────────────────────────


async def test_invalid_resolution_rejected(tenant_creds):
    _, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]

    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(client, headers, tenant_creds, session.id, rec.id, {"resolution": "confirm"})
    assert resp.status_code == 422


async def test_ignore_with_quantity_rejected(tenant_creds):
    _, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]

    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(
            client, headers, tenant_creds, session.id, rec.id, {"resolution": "ignore", "detected_quantity": 12}
        )
    assert resp.status_code == 422


# ── 6. ai.reconcile permission → 403 ─────────────────────────────────────────


async def test_reconcile_permission_403(tenant_creds):
    _, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]
    restricted = await _restricted_user(tenant_creds, permissions=["ai.view"])
    login_resp = await login({"email": restricted["email"], "password": restricted["password"]})
    assert login_resp.status_code == 200

    client, _ = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(
            client,
            {"Authorization": f"Bearer {login_resp.json()['access_token']}"},
            tenant_creds,
            session.id,
            rec.id,
            {"resolution": "ignore"},
        )
    assert resp.status_code == 403
    assert resp.json()["detail"]["code"] == "FORBIDDEN"


# ── 6b. ai.view can read reconciliation rows but not mutate them ──────────────


async def test_view_only_can_read_reconciliations_not_mutate(tenant_creds):
    _, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]
    restricted = await _restricted_user(tenant_creds, permissions=["ai.view"])
    login_resp = await login({"email": restricted["email"], "password": restricted["password"]})
    assert login_resp.status_code == 200
    headers = {"Authorization": f"Bearer {login_resp.json()['access_token']}"}

    client, _ = await _authed_client(tenant_creds)
    async with client:
        read_resp = await client.get(
            f"/ai/scans/{session.id}/reconciliations",
            params={"store_id": str(tenant_creds["store_id"])},
            headers=headers,
        )
        assert read_resp.status_code == 200
        rows = read_resp.json()
        assert len(rows) == 1
        assert rows[0]["id"] == str(rec.id)

        patch_resp = await client.patch(
            f"/ai/scans/{session.id}/reconciliations/{rec.id}",
            params={"store_id": str(tenant_creds["store_id"])},
            headers=headers,
            json={"resolution": "ignore"},
        )
        assert patch_resp.status_code == 403
        assert patch_resp.json()["detail"]["code"] == "FORBIDDEN"


async def test_cross_tenant_404():
    tenant_a = await make_tenant(f"owner-a-{uuid.uuid4().hex[:8]}@test.dev")
    tenant_b = await make_tenant(f"owner-b-{uuid.uuid4().hex[:8]}@test.dev")
    try:
        _, session, recs = await _reviewed_session(tenant_a, [_barcode_item(BARCODE_A, 3)])
        rec = recs[0]
        client_b, headers_b = await _authed_client(tenant_b)
        async with client_b:
            resp = await client_b.patch(
                f"/ai/scans/{session.id}/reconciliations/{rec.id}",
                params={"store_id": str(tenant_a["store_id"])},
                headers=headers_b,
                json={"resolution": "ignore"},
            )
        assert resp.status_code == 404
        assert resp.json()["detail"]["code"] == "NOT_FOUND"
    finally:
        await cleanup_tenant(tenant_a)
        await cleanup_tenant(tenant_b)


async def test_cross_store_404(tenant_creds):
    _, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]

    async with SessionLocal() as db:
        other = Store(tenant_id=tenant_creds["tenant_id"], name="North")
        db.add(other)
        await db.commit()
        await db.refresh(other)
        other_store_id = other.id

    restricted = await _restricted_user(tenant_creds, permissions=["ai.reconcile"], store_id=other_store_id)
    login_resp = await login({"email": restricted["email"], "password": restricted["password"]})
    assert login_resp.status_code == 200

    client, _ = await _authed_client(tenant_creds)
    async with client:
        resp = await client.patch(
            f"/ai/scans/{session.id}/reconciliations/{rec.id}",
            params={"store_id": str(other_store_id)},
            headers={"Authorization": f"Bearer {login_resp.json()['access_token']}"},
            json={"resolution": "ignore"},
        )
    assert resp.status_code == 404
    assert resp.json()["detail"]["code"] == "NOT_FOUND"


# ── 8. Wrong scan ↔ reconciliation relationship → 404 ────────────────────────


async def test_reconciliation_from_another_scan_404(tenant_creds):
    env = await _scan_env(tenant_creds)
    s1 = await _create(tenant_creds)
    await _process(tenant_creds, s1.id, FakeVisionPort([_barcode_item(BARCODE_A, 3)]))
    # A confirmable second session (own reconciliation rows) — rec1 belongs to s1 only.
    s2 = await _create(tenant_creds)
    await _process(tenant_creds, s2.id, FakeVisionPort([_barcode_item(BARCODE_B, 2)]))
    rec1 = (await _reconciliations(s1.id))[0]
    assert rec1.product_id == env["product_a"]

    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(client, headers, tenant_creds, s2.id, rec1.id, {"resolution": "ignore"})
    assert resp.status_code == 404
    assert resp.json()["detail"]["code"] == "NOT_FOUND"


async def test_unknown_reconciliation_404(tenant_creds):
    _, session, _ = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(
            client, headers, tenant_creds, session.id, uuid.uuid4(), {"resolution": "ignore"}
        )
    assert resp.status_code == 404
    assert resp.json()["detail"]["code"] == "NOT_FOUND"


# ── 9. Ignored reconciliation does not mutate inventory ──────────────────────
# (see test_ignore_resolution above — asserted inventory + movements)


# ── 10. Override becomes the COUNT target ────────────────────────────────────


async def test_override_becomes_count_target(tenant_creds):
    env, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]

    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(
            client, headers, tenant_creds, session.id, rec.id, {"resolution": "apply", "detected_quantity": 14}
        )
    assert resp.status_code == 200, resp.text

    await _confirm(tenant_creds, session.id)
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(14)
    moves = await _count_movements(tenant_creds["store_id"], session.id)
    assert len(moves) == 1
    assert moves[0].product_id == env["product_a"]
    assert moves[0].quantity_delta == Decimal(4)
    assert moves[0].resulting_quantity == Decimal(14)


async def test_override_to_zero_is_zero_count_target(tenant_creds):
    env, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]

    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(
            client, headers, tenant_creds, session.id, rec.id, {"resolution": "apply", "detected_quantity": 0}
        )
    assert resp.status_code == 200, resp.text

    await _confirm(tenant_creds, session.id)
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(0)
    moves = await _count_movements(tenant_creds["store_id"], session.id)
    assert len(moves) == 1
    assert moves[0].quantity_delta == Decimal(-10)
    assert moves[0].resulting_quantity == Decimal(0)


# ── 11. Double confirm still 409 ─────────────────────────────────────────────


async def test_double_confirm_still_409(tenant_creds):
    _, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]

    client, headers = await _authed_client(tenant_creds)
    async with client:
        r1 = await _review(client, headers, tenant_creds, session.id, rec.id, {"resolution": "apply"})
        assert r1.status_code == 200, r1.text
        c1 = await _confirm_scan(client, headers, tenant_creds, session.id)
        assert c1.status_code == 200, c1.text
        c2 = await _confirm_scan(client, headers, tenant_creds, session.id)
    assert c2.status_code == 409
    assert c2.json()["detail"]["code"] == "CONFLICT"
    assert len(await _count_movements(tenant_creds["store_id"], session.id)) == 1


# ── 12. Stale inventory still 409 ────────────────────────────────────────────


async def test_stale_inventory_still_409(tenant_creds):
    env, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]

    client, headers = await _authed_client(tenant_creds)
    async with client:
        r = await _review(
            client, headers, tenant_creds, session.id, rec.id, {"resolution": "apply", "detected_quantity": 12}
        )
        assert r.status_code == 200, r.text
        adjusted = await client.patch(
            f"/inventory/stock/{env['product_a']}",
            params={"store_id": str(tenant_creds["store_id"])},
            headers=headers,
            json={"new_quantity": "7", "reason": "sale after review"},
        )
        assert adjusted.status_code == 200, adjusted.text
        c = await _confirm_scan(client, headers, tenant_creds, session.id)
    assert c.status_code == 409
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(7)
    assert await _count_movements(tenant_creds["store_id"], session.id) == []


# ── 13. Rollback remains atomic ──────────────────────────────────────────────


async def test_rollback_remains_atomic(tenant_creds):
    env, session, recs = await _reviewed_session(
        tenant_creds, [_barcode_item(BARCODE_A, 3), _barcode_item(BARCODE_B, 2)]
    )
    a = next(r for r in recs if r.product_id == env["product_a"])
    b = next(r for r in recs if r.product_id == env["product_b"])

    client, headers = await _authed_client(tenant_creds)
    async with client:
        ra = await _review(
            client, headers, tenant_creds, session.id, a.id, {"resolution": "apply", "detected_quantity": 12}
        )
        assert ra.status_code == 200, ra.text
        rb = await _review(client, headers, tenant_creds, session.id, b.id, {"resolution": "ignore"})
        assert rb.status_code == 200, rb.text
        adjusted = await client.patch(
            f"/inventory/stock/{env['product_a']}",
            params={"store_id": str(tenant_creds["store_id"])},
            headers=headers,
            json={"new_quantity": "7", "reason": "external change"},
        )
        assert adjusted.status_code == 200, adjusted.text
        c = await _confirm_scan(client, headers, tenant_creds, session.id)
    assert c.status_code == 409

    # Nothing partially applied; review decisions survive the failed confirm.
    assert await _inventory(tenant_creds["store_id"], env["product_a"]) == Decimal(7)
    assert await _inventory(tenant_creds["store_id"], env["product_b"]) == Decimal(10)
    assert await _count_movements(tenant_creds["store_id"], session.id) == []
    assert await _audit_rows(session.id) == []
    assert await _session_status(session.id) == SESSION_STATUS_COMPLETED

    recs_after = await _reconciliations(session.id)
    after = {r.product_id: r for r in recs_after}
    assert after[env["product_a"]].resolution == "apply"
    assert after[env["product_a"]].detected_quantity == Decimal(12)
    assert after[env["product_a"]].confirmed_by is None
    assert after[env["product_b"]].resolution == "ignore"


# ── 14. Audit records the review decision ────────────────────────────────────


async def test_audit_records_review_decision(tenant_creds):
    _, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]

    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(
            client, headers, tenant_creds, session.id, rec.id, {"resolution": "apply", "detected_quantity": 12}
        )
    assert resp.status_code == 200, resp.text

    async with SessionLocal() as db:
        rows = (
            await db.execute(
                select(AuditLog).where(
                    AuditLog.action == "reconciliation_updated", AuditLog.entity_id == str(rec.id)
                )
            )
        ).scalars().all()
    assert len(rows) == 1
    row = rows[0]
    assert row.entity_type == "scan_reconciliation"
    assert row.tenant_id == tenant_creds["tenant_id"]
    assert row.store_id == tenant_creds["store_id"]
    assert row.user_id == tenant_creds["user_id"]
    assert row.before["detected_quantity"] == "3.000"
    assert row.after["resolution"] == "apply"
    assert row.after["detected_quantity"] == "12"
    assert row.after["variance"] == "2.000"


# ── Closed / invalid scan states → 409 ───────────────────────────────────────


async def test_processing_session_cannot_be_reviewed(tenant_creds):
    env = await _scan_env(tenant_creds)
    session = await _create(tenant_creds)  # still PROCESSING, no reconciliation rows

    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(
            client, headers, tenant_creds, session.id, uuid.uuid4(), {"resolution": "ignore"}
        )
    assert resp.status_code == 409
    assert resp.json()["detail"]["code"] == "CONFLICT"
    assert env is not None


async def test_confirmed_session_cannot_be_reviewed(tenant_creds):
    _, session, recs = await _reviewed_session(tenant_creds, [_barcode_item(BARCODE_A, 3)])
    rec = recs[0]
    await _confirm(tenant_creds, session.id)

    client, headers = await _authed_client(tenant_creds)
    async with client:
        resp = await _review(client, headers, tenant_creds, session.id, rec.id, {"resolution": "ignore"})
    assert resp.status_code == 409
    assert resp.json()["detail"]["code"] == "CONFLICT"
