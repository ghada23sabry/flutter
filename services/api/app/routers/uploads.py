"""Image upload router for product images."""
import io
import logging
import mimetypes
import uuid
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Depends, Query, UploadFile
from fastapi.responses import FileResponse
from PIL import Image
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.core.db import get_db
from app.core.errors import CODE_NOT_FOUND, CODE_VALIDATION_ERROR, AppError
from app.core.security import AuthContext, require_permission
from app.models.catalog import Product
from app.schemas import ActionResponse
from app.services.catalog_service import get_scoped_product

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/uploads", tags=["uploads"])

PERMISSION_MANAGE = "products.manage"

ALLOWED_TYPES = {"image/jpeg", "image/png", "image/webp", "image/gif"}

MAX_DIMENSION = 1600
JPEG_QUALITY = 85


def _ensure_upload_dir(store_id: uuid.UUID) -> Path:
    settings = get_settings()
    upload_dir = Path(settings.upload_dir) / str(store_id)
    upload_dir.mkdir(parents=True, exist_ok=True)
    return upload_dir


def _compress_image(raw: bytes, content_type: str) -> tuple[bytes, str]:
    img = Image.open(io.BytesIO(raw))
    if img.mode in ("RGBA", "P"):
        img = img.convert("RGB")

    w, h = img.size
    if max(w, h) > MAX_DIMENSION:
        ratio = MAX_DIMENSION / max(w, h)
        img = img.resize((int(w * ratio), int(h * ratio)), Image.LANCZOS)

    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=JPEG_QUALITY, optimize=True)
    return buf.getvalue(), "jpg"


@router.get("/products/{product_id}/image")
async def get_product_image(
    product_id: uuid.UUID,
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    """Serve a product's uploaded image. Store scoping prevents cross-tenant
    access. No full auth required — image URLs are non-sensitive."""
    product = (
        await db.execute(
            select(Product).where(
                Product.id == product_id,
                Product.store_id == store_id,
            )
        )
    ).scalar_one_or_none()

    if product is None or not product.image_url:
        raise AppError(CODE_NOT_FOUND, "Image not found", 404)

    settings = get_settings()
    upload_dir = Path(settings.upload_dir) / str(store_id)

    for ext in ("jpg", "jpeg", "png", "webp", "gif"):
        filepath = upload_dir / f"{product_id}.{ext}"
        if filepath.is_file():
            media_type = mimetypes.guess_type(filepath.name)[0] or "image/jpeg"
            return FileResponse(filepath, media_type=media_type)

    raise AppError(CODE_NOT_FOUND, "Image file not found on disk", 404)


@router.post("/products/{product_id}/image", response_model=ActionResponse)
async def upload_product_image(
    product_id: uuid.UUID,
    file: UploadFile,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_MANAGE))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    if file.content_type not in ALLOWED_TYPES:
        raise AppError(
            CODE_VALIDATION_ERROR,
            f"Unsupported image type: {file.content_type}. Allowed: jpeg, png, webp, gif",
            422,
        )

    settings = get_settings()
    max_bytes = settings.max_upload_size_mb * 1024 * 1024
    contents = await file.read()
    if len(contents) > max_bytes:
        raise AppError(
            CODE_VALIDATION_ERROR,
            f"File too large: {len(contents)} bytes (max {settings.max_upload_size_mb}MB)",
            422,
        )

    product = await get_scoped_product(db, ctx, store_id, product_id)

    compressed, ext = _compress_image(contents, file.content_type)

    upload_dir = _ensure_upload_dir(store_id)

    for old_ext in ("jpg", "jpeg", "png", "webp", "gif"):
        old = upload_dir / f"{product_id}.{old_ext}"
        if old.exists():
            old.unlink()
            break

    filename = f"{product_id}.{ext}"
    filepath = upload_dir / filename
    filepath.write_bytes(compressed)

    image_url = f"/uploads/products/{product_id}/image"
    product.image_url = image_url
    await db.commit()

    logger.info(
        "Product image uploaded: product_id=%s store_id=%s original=%d compressed=%d",
        product_id,
        store_id,
        len(contents),
        len(compressed),
    )
    return ActionResponse(status="ok")


@router.delete("/products/{product_id}/image", response_model=ActionResponse)
async def delete_product_image(
    product_id: uuid.UUID,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_MANAGE))],
    db: Annotated[AsyncSession, Depends(get_db)],
    store_id: Annotated[uuid.UUID, Query()],
):
    product = await get_scoped_product(db, ctx, store_id, product_id)
    if product.image_url:
        upload_dir = _ensure_upload_dir(store_id)
        for ext in ("jpg", "jpeg", "png", "webp", "gif"):
            filepath = upload_dir / f"{product_id}.{ext}"
            if filepath.exists():
                filepath.unlink()
                break
        product.image_url = None
        await db.commit()
    return ActionResponse(status="ok")
