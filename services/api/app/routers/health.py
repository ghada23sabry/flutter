import logging
from typing import Annotated

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import get_db

logger = logging.getLogger(__name__)

router = APIRouter(tags=["system"])


@router.get("/health")
async def health(db: Annotated[AsyncSession, Depends(get_db)]):
    try:
        await db.execute(text("SELECT 1"))
    except Exception as exc:  # noqa: BLE001
        error_type = type(exc).__name__
        error_message = str(exc)

        logger.warning(
            "DATABASE HEALTH ERROR type=%s message=%s",
            error_type,
            error_message,
        )

        return JSONResponse(
            status_code=503,
            content={
                "status": "degraded",
                "database": "unavailable",
                "service": "visionstock-api",
                "error_type": error_type,
                "error": error_message,
            },
        )

    return {
        "status": "ok",
        "database": "ok",
        "service": "visionstock-api",
        "version": "0.1.0",
    }