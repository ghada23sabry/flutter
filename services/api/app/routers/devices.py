import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import get_db
from app.core.errors import CODE_CONFLICT, CODE_NOT_FOUND, AppError
from app.core.security import AuthContext, get_auth_context, require_permission
from app.models import Device, UserRole
from app.schemas.auth import DeviceOut, DeviceRegisterRequest, RevokeResponse
from app.services.auth_service import revoke_device

router = APIRouter(prefix="/devices", tags=["devices"])

PERMISSION_VIEW = "devices.view"
PERMISSION_REVOKE = "devices.revoke"


@router.get("", response_model=list[DeviceOut])
async def list_devices(
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_VIEW))],
    db: Annotated[AsyncSession, Depends(get_db)],
):
    query = select(Device).where(Device.tenant_id == ctx.tenant.id)
    user_roles = (await db.execute(select(UserRole).where(UserRole.user_id == ctx.user.id))).scalars().all()
    if not any(role.store_id is None for role in user_roles):
        accessible_ids = [store.id for store in ctx.accessible_stores]
        if not accessible_ids:
            return []
        query = query.where(Device.store_id.in_(accessible_ids))
    devices = (await db.execute(query.order_by(Device.created_at.desc()))).scalars().all()
    return [DeviceOut.model_validate(d) for d in devices]


@router.post("/register", response_model=DeviceOut, status_code=201)
async def register_device(
    body: DeviceRegisterRequest,
    request: Request,
    ctx: Annotated[AuthContext, Depends(get_auth_context)],
    db: Annotated[AsyncSession, Depends(get_db)],
):
    if not ctx.can_access_store(body.store_id):
        raise AppError(CODE_NOT_FOUND, "Store not found", 404)
    existing = (
        await db.execute(
            select(Device).where(Device.tenant_id == ctx.tenant.id, Device.device_uuid == body.device_uuid)
        )
    ).scalar_one_or_none()
    if existing is not None:
        if existing.status == "active":
            raise AppError(CODE_CONFLICT, "Device is already registered", 409)
        existing.status = "active"
        existing.store_id = body.store_id
        existing.name = body.name or existing.name
        existing.platform = body.platform or existing.platform
        existing.model = body.model or existing.model
        existing.push_token = body.push_token or existing.push_token
        await db.commit()
        return DeviceOut.model_validate(existing)

    device = Device(
        tenant_id=ctx.tenant.id,
        store_id=body.store_id,
        device_uuid=body.device_uuid,
        name=body.name,
        platform=body.platform,
        model=body.model,
        push_token=body.push_token,
        status="active",
        registered_by=ctx.user.id,
    )
    db.add(device)
    await db.commit()
    return DeviceOut.model_validate(device)


@router.post("/{device_id}/revoke", response_model=RevokeResponse)
async def revoke_endpoint(
    device_id: uuid.UUID,
    request: Request,
    ctx: Annotated[AuthContext, Depends(require_permission(PERMISSION_REVOKE))],
    db: Annotated[AsyncSession, Depends(get_db)],
):
    await revoke_device(db, request, ctx, device_id)
    return RevokeResponse()
