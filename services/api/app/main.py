import logging
import subprocess
import sys
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import get_settings
from app.core.errors import register_error_handlers
from app.core.logging import AsyncLoggingSetup
from app.routers import ai, auth, categories, devices, health, inventory, products, suppliers, users

_logging_setup = AsyncLoggingSetup()
_log = logging.getLogger("visionstock.startup")


def _run_migrations() -> None:
    """Run alembic upgrade head. Blocks startup until DB is ready."""
    _log.info("Running database migrations...")
    try:
        result = subprocess.run(
            [sys.executable, "-m", "alembic", "upgrade", "head"],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        if result.returncode != 0:
            _log.error("Migration failed:\n%s", result.stderr)
        else:
            _log.info("Migrations applied successfully.")
    except FileNotFoundError:
        _log.warning("alembic not found — skipping migrations (expected in dev).")
    except subprocess.TimeoutExpired:
        _log.error("Migrations timed out after 120s.")


def _seed_defaults() -> None:
    """Seed Acme tenant if missing. Idempotent."""
    _log.info("Seeding default tenant...")
    try:
        result = subprocess.run(
            [
                sys.executable, "-m", "app.cli",
                "create-tenant",
                "--name", "Acme",
                "--slug", "acme",
                "--email", "owner@acme.com",
                "--password", "Test1234!",
                "--store", "Downtown",
            ],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        if "already exists" in result.stdout.lower() or "already exists" in result.stderr.lower():
            _log.info("Tenant already exists, skipping seed.")
        elif result.returncode != 0:
            _log.warning("Seed returned non-zero (may already exist):\n%s", result.stderr)
        else:
            _log.info("Default tenant seeded.")
    except (subprocess.SubprocessError, OSError) as exc:
        _log.warning("Seed failed: %s", exc)


@asynccontextmanager
async def lifespan(app: FastAPI):
    _logging_setup.configure()
    _run_migrations()
    _seed_defaults()
    yield
    _logging_setup.shutdown()


settings = get_settings()

app = FastAPI(title=settings.app_name, version="0.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

register_error_handlers(app)

app.include_router(health.router)
app.include_router(auth.router)
app.include_router(devices.router)
app.include_router(users.router)
app.include_router(categories.router)
app.include_router(products.router)
app.include_router(suppliers.router)
app.include_router(inventory.router)
app.include_router(ai.router)
