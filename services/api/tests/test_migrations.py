"""Fresh-database migration-chain verification (A11.5 + first-release sprint).

Runs `alembic upgrade head` (0001 -> 0009) against an isolated scratch
database that is created before the run and dropped after it, then asserts the
resulting schema:

- `alembic_version` == head (0009), single chain, no branches
- every model table exists (identity / catalog / inventory / AI)
- `scan_sessions.status` server default == 'processing' (migration 0006)
- `scan_sessions.operation` server default == 'count' (migration 0008)
- `scan_reconciliations` carries the A10 review fields (resolution,
  confirmed_by, confirmed_at) plus detected/system/variance
- `inventory.version` exists (optimistic-lock column)
- the four `ai.*` permissions are seeded and granted to the system
  `owner` + `admin` roles (migration 0005)
- the partial unique index `uq_stock_movements_scan_session` exists with the
  documented SCAN_SESSION predicate (migration 0008, widened from 0007)
- `product_recognitions` table exists (migration 0009)

The migrations run in a subprocess (fresh settings cache, same as the CLI),
so the running test process and its engine are never touched. The scratch DB
is owned by the app role so the app DATABASE_URL credentials work unchanged.

Scratch-DB creation requires a superuser connection. It is derived from the
app DATABASE_URL: same host/port, user `postgres`, database `postgres`, and
the password from `TEST_PG_SUPERUSER_PASSWORD` (default: the app URL's own
password — the local dev convention). Set `TEST_PG_SUPERUSER_URL` to override
the whole superuser DSN (e.g. in CI).
"""
import asyncio
import os
import subprocess
import sys
import urllib.parse
import uuid
from pathlib import Path

import asyncpg

from app.config import get_settings

API_DIR = Path(__file__).resolve().parents[1]

EXPECTED_TABLES = {
    "tenants",
    "stores",
    "users",
    "roles",
    "permissions",
    "role_permissions",
    "user_roles",
    "devices",
    "device_sessions",
    "audit_logs",
    "categories",
    "suppliers",
    "products",
    "product_visual_profiles",
    "supplier_products",
    "zones",
    "shelves",
    "shelf_product_map",
    "inventory",
    "stock_movements",
    "expiry_batches",
    "scan_sessions",
    "scan_detections",
    "scan_reconciliations",
    "product_recognitions",
    "product_visual_recognitions",
}

AI_PERMISSIONS = {"ai.scan", "ai.reconcile", "ai.confirm", "ai.view"}

RECONCILIATION_COLUMNS = {
    "detected_quantity",
    "system_quantity",
    "variance",
    "status",
    "resolution",
    "confirmed_by",
    "confirmed_at",
}

MOVEMENT_COLUMNS = {
    "quantity_delta",
    "resulting_quantity",
    "movement_type",
    "reference_type",
    "reference_id",
}


def _app_dsn() -> str:
    return get_settings().database_url


def _scratch_db_name() -> str:
    return f"visionstock_mig_test_{uuid.uuid4().hex[:8]}"


def _parse_dsn(dsn: str) -> dict:
    p = urllib.parse.urlparse(dsn)
    return {
        "host": p.hostname,
        "port": p.port or 5432,
        "user": p.username,
        "password": p.password,
        "database": p.path.lstrip("/"),
    }


def _superuser_dsn() -> str:
    override = os.environ.get("TEST_PG_SUPERUSER_URL")
    if override:
        return override
    app = _parse_dsn(_app_dsn())
    password = os.environ.get("TEST_PG_SUPERUSER_PASSWORD") or app["password"] or ""
    return (
        f"postgresql://postgres:{urllib.parse.quote(password)}"
        f"@{app['host']}:{app['port']}/postgres"
    )


async def _drop_database(conn: asyncpg.Connection, dbname: str) -> None:
    await conn.execute(
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()",
        dbname,
    )
    await conn.execute(f'DROP DATABASE IF EXISTS "{dbname}"')


def _run_alembic(db_url: str) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["DATABASE_URL"] = db_url
    return subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        cwd=str(API_DIR),
        env=env,
        capture_output=True,
        text=True,
        timeout=240,
        check=False,
    )


async def _assert_schema(conn: asyncpg.Connection) -> None:
    version = await conn.fetchval("SELECT version_num FROM alembic_version")
    assert version == "0011", f"expected alembic head 0011, got {version!r}"

    tables = {
        row[0]
        for row in await conn.fetch(
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public'"
        )
    }
    missing = EXPECTED_TABLES - tables
    assert not missing, f"tables missing after upgrade head: {sorted(missing)}"

    status_default = await conn.fetchval(
        "SELECT column_default FROM information_schema.columns "
        "WHERE table_schema = 'public' AND table_name = 'scan_sessions' AND column_name = 'status'"
    )
    assert status_default and status_default.startswith("'processing'"), (
        f"expected scan_sessions.status default 'processing' (migration 0006), got {status_default!r}"
    )

    operation_default = await conn.fetchval(
        "SELECT column_default FROM information_schema.columns "
        "WHERE table_schema = 'public' AND table_name = 'scan_sessions' AND column_name = 'operation'"
    )
    assert operation_default and operation_default.startswith("'count'"), (
        f"expected scan_sessions.operation default 'count' (migration 0008), got {operation_default!r}"
    )

    rec_columns = {
        row[0]
        for row in await conn.fetch(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_schema = 'public' AND table_name = 'scan_reconciliations'"
        )
    }
    missing_rec = RECONCILIATION_COLUMNS - rec_columns
    assert not missing_rec, f"scan_reconciliations missing columns: {sorted(missing_rec)}"

    inv_columns = {
        row[0]
        for row in await conn.fetch(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_schema = 'public' AND table_name = 'inventory'"
        )
    }
    assert "version" in inv_columns, "inventory.version (optimistic-lock) column missing"

    move_columns = {
        row[0]
        for row in await conn.fetch(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_schema = 'public' AND table_name = 'stock_movements'"
        )
    }
    missing_move = MOVEMENT_COLUMNS - move_columns
    assert not missing_move, f"stock_movements missing columns: {sorted(missing_move)}"

    permissions = {
        row[0]
        for row in await conn.fetch("SELECT code FROM permissions")
    }
    missing_perms = AI_PERMISSIONS - permissions
    assert not missing_perms, f"ai.* permissions not seeded: {sorted(missing_perms)}"

    grants = {
        (role, perm)
        for role, perm in await conn.fetch(
            "SELECT r.name, p.code FROM role_permissions rp "
            "JOIN roles r ON r.id = rp.role_id "
            "JOIN permissions p ON p.id = rp.permission_id "
            "WHERE r.tenant_id IS NULL AND r.name IN ('owner', 'admin')"
        )
    }
    expected_grants = {(role, perm) for role in ("owner", "admin") for perm in AI_PERMISSIONS}
    missing_grants = expected_grants - grants
    assert not missing_grants, f"owner/admin ai.* grants missing: {sorted(missing_grants)}"

    indexdef = await conn.fetchval(
        "SELECT indexdef FROM pg_indexes "
        "WHERE schemaname = 'public' AND indexname = 'uq_stock_movements_scan_session'"
    )
    assert indexdef is not None, "uq_stock_movements_scan_session index missing"
    assert "SCAN_SESSION" in indexdef, f"unexpected index predicate: {indexdef}"

    old_index = await conn.fetchval(
        "SELECT indexdef FROM pg_indexes "
        "WHERE schemaname = 'public' AND indexname = 'uq_stock_movements_scan_count'"
    )
    assert old_index is None, "migration 0008 must replace the COUNT-only dedup index"


async def _run() -> None:
    scratch = _scratch_db_name()
    app = _parse_dsn(_app_dsn())

    admin = await asyncpg.connect(**_parse_dsn(_superuser_dsn()))
    try:
        await admin.execute(f'CREATE DATABASE "{scratch}" OWNER "{app["user"]}"')
    finally:
        await admin.close()

    try:
        result = _run_alembic(f"postgresql+asyncpg://{app['user']}:{app['password']}@{app['host']}:{app['port']}/{scratch}")
        assert result.returncode == 0, (
            f"alembic upgrade head failed on a fresh database\n"
            f"--- stdout ---\n{result.stdout}\n--- stderr ---\n{result.stderr}"
        )

        conn = await asyncpg.connect(host=app["host"], port=app["port"], user=app["user"], password=app["password"], database=scratch)
        try:
            await _assert_schema(conn)
        finally:
            await conn.close()
    finally:
        admin = await asyncpg.connect(**_parse_dsn(_superuser_dsn()))
        try:
            await _drop_database(admin, scratch)
        finally:
            await admin.close()


async def test_migration_chain_from_empty_database():
    await asyncio.wait_for(_run(), timeout=300)
