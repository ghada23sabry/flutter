from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import get_settings
from app.core.errors import register_error_handlers
from app.core.logging import AsyncLoggingSetup
from app.routers import ai, auth, categories, devices, health, inventory, products, suppliers, users

_logging_setup = AsyncLoggingSetup()


@asynccontextmanager
async def lifespan(app: FastAPI):
    _logging_setup.configure()
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
