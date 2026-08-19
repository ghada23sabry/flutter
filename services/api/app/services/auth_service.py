import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from fastapi import Request
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.core.audit import write_audit
from app.core.errors import (
    CODE_ACCOUNT_DISABLED,
    CODE_DEVICE_REVOKED,
    CODE_INVALID_CREDENTIALS,
    CODE_NOT_FOUND,
    CODE_SESSION_EXPIRED,
    CODE_UNAUTHORIZED,
    AppError,
)
from app.core.security import (
    AuthContext,
    client_ip,
    create_access_token,
    generate_refresh_token,
    hash_token,
    verify_password,
)
from app.models import Device, DeviceSession, Permission, Role, RolePermission, Store, Tenant, User, UserRole
from app.schemas.auth import DeviceInfo, DeviceOut, MeResponse, StoreOut, UserOut


@dataclass
class LoginResult:
    access_token: str
    refresh_token: str
    expires_in: int
    user: UserOut
    permissions: list[str]
    stores: list[StoreOut]
    device: DeviceOut | None


async def _effective_permissions(db: AsyncSession, user_id: uuid.UUID) -> list[str]:
    role_ids = (
        await db.execute(select(Role.id).join(UserRole, UserRole.role_id == Role.id).where(UserRole.user_id == user_id))
    ).scalars().all()
    if not role_ids:
        return []
    codes = (
        await db.execute(
            select(Permission.code)
            .join(RolePermission, RolePermission.permission_id == Permission.id)
            .where(RolePermission.role_id.in_(role_ids))
        )
    ).scalars().all()
    return sorted(set(codes))


async def _accessible_stores(db: AsyncSession, user_id: uuid.UUID, tenant_id: uuid.UUID) -> list[Store]:
    tenant_stores = (await db.execute(select(Store).where(Store.tenant_id == tenant_id))).scalars().all()
    user_roles = (await db.execute(select(UserRole).where(UserRole.user_id == user_id))).scalars().all()
    if any(ur.store_id is None for ur in user_roles):
        return list(tenant_stores)
    store_ids = {ur.store_id for ur in user_roles if ur.store_id is not None}
    return [s for s in tenant_stores if s.id in store_ids]


async def _resolve_login_device(
    db: AsyncSession,
    tenant_id: uuid.UUID,
    store_id: uuid.UUID | None,
    device_info: DeviceInfo,
    user_id: uuid.UUID,
) -> Device:
    device = (
        await db.execute(
            select(Device).where(Device.tenant_id == tenant_id, Device.device_uuid == device_info.device_uuid)
        )
    ).scalar_one_or_none()
    if device is None:
        device = Device(
            tenant_id=tenant_id,
            store_id=store_id,
            device_uuid=device_info.device_uuid,
            name=device_info.name,
            platform=device_info.platform,
            model=device_info.model,
            push_token=device_info.push_token,
            status="active",
            registered_by=user_id,
        )
        db.add(device)
        await db.flush()
    elif device.status != "active":
        raise AppError(CODE_DEVICE_REVOKED, "Device is revoked or locked", 401)
    return device


async def login(
    db: AsyncSession,
    request: Request,
    *,
    email: str,
    password: str,
    device_info: DeviceInfo | None,
) -> LoginResult:
    user = (
        await db.execute(select(User).where(func.lower(User.email) == email.lower()))
    ).scalar_one_or_none()

    if user is None or not verify_password(password, user.password_hash):
        await write_audit(
            db, action="login_failure", entity_type="auth", after={"reason": "invalid_credentials"}, ip=client_ip(request)
        )
        await db.commit()
        raise AppError(CODE_INVALID_CREDENTIALS, "Invalid email or password", 401)

    if user.status != "active":
        await write_audit(
            db,
            action="login_failure",
            entity_type="auth",
            tenant_id=user.tenant_id,
            user_id=user.id,
            after={"reason": "account_disabled"},
            ip=client_ip(request),
        )
        await db.commit()
        raise AppError(CODE_ACCOUNT_DISABLED, "Account is disabled", 403)

    tenant = await db.get(Tenant, user.tenant_id) if user.tenant_id else None
    if tenant is None or tenant.status != "active":
        await write_audit(
            db, action="login_failure", entity_type="auth", user_id=user.id, after={"reason": "tenant_inactive"}
        )
        await db.commit()
        raise AppError(CODE_ACCOUNT_DISABLED, "Account is disabled", 403)

    stores = await _accessible_stores(db, user.id, tenant.id)
    store_id = stores[0].id if stores else None

    device: Device | None = None
    if device_info is not None:
        device = await _resolve_login_device(db, tenant.id, store_id, device_info, user.id)

    settings = get_settings()
    refresh_token = generate_refresh_token()
    session = DeviceSession(
        tenant_id=tenant.id,
        store_id=device.store_id if device else store_id,
        user_id=user.id,
        device_id=device.id if device else None,
        token_hash=hash_token(refresh_token),
        refresh_expires_at=datetime.now(UTC) + timedelta(days=settings.refresh_token_expire_days),
        status="active",
        ip=client_ip(request),
        user_agent=(request.headers.get("user-agent") or "")[:255],
    )
    db.add(session)
    await db.flush()

    access_token = create_access_token(
        user_id=user.id, tenant_id=tenant.id, session_id=session.id, device_id=device.id if device else None
    )

    await write_audit(
        db,
        action="login_success",
        entity_type="auth",
        entity_id=str(session.id),
        tenant_id=tenant.id,
        store_id=session.store_id,
        user_id=user.id,
        ip=client_ip(request),
    )
    await db.commit()

    permissions = await _effective_permissions(db, user.id)
    return LoginResult(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=settings.access_token_expire_minutes * 60,
        user=UserOut.model_validate(user),
        permissions=permissions,
        stores=[StoreOut.model_validate(s) for s in stores],
        device=DeviceOut.model_validate(device) if device else None,
    )


async def refresh(db: AsyncSession, request: Request, refresh_token: str) -> tuple[str, str, int]:
    token_hash = hash_token(refresh_token)
    session = (
        await db.execute(
            select(DeviceSession).where(DeviceSession.token_hash == token_hash, DeviceSession.status == "active")
        )
    ).scalar_one_or_none()
    if session is None:
        raise AppError(CODE_UNAUTHORIZED, "Invalid refresh token", 401)

    if session.refresh_expires_at < datetime.now(UTC):
        session.status = "expired"
        await db.commit()
        raise AppError(CODE_SESSION_EXPIRED, "Session has expired", 401)

    user = await db.get(User, session.user_id)
    if user is None or user.status != "active":
        session.status = "revoked"
        await db.commit()
        raise AppError(CODE_ACCOUNT_DISABLED, "Account is disabled", 403)

    if session.device_id is not None:
        device = await db.get(Device, session.device_id)
        if device is None or device.status != "active":
            session.status = "revoked"
            await db.commit()
            raise AppError(CODE_DEVICE_REVOKED, "Device is revoked or locked", 401)

    settings = get_settings()
    new_refresh = generate_refresh_token()
    session.token_hash = hash_token(new_refresh)
    session.refresh_expires_at = datetime.now(UTC) + timedelta(days=settings.refresh_token_expire_days)
    session.last_used_at = datetime.now(UTC)

    access_token = create_access_token(
        user_id=user.id, tenant_id=session.tenant_id, session_id=session.id, device_id=session.device_id
    )
    await write_audit(
        db,
        action="token_refresh",
        entity_type="auth",
        entity_id=str(session.id),
        tenant_id=session.tenant_id,
        store_id=session.store_id,
        user_id=user.id,
        ip=client_ip(request),
    )
    await db.commit()
    return access_token, new_refresh, settings.access_token_expire_minutes * 60


async def logout(db: AsyncSession, request: Request, ctx: AuthContext) -> None:
    session = ctx.device_session
    session.status = "revoked"
    session.revoked_at = datetime.now(UTC)
    await write_audit(
        db,
        action="logout",
        entity_type="auth",
        entity_id=str(session.id),
        tenant_id=ctx.tenant.id,
        store_id=session.store_id,
        user_id=ctx.user.id,
        ip=client_ip(request),
    )
    await db.commit()


async def revoke_device(db: AsyncSession, request: Request, ctx: AuthContext, device_id: uuid.UUID) -> None:
    device = await db.get(Device, device_id)
    if device is None or device.tenant_id != ctx.tenant.id:
        raise AppError(CODE_NOT_FOUND, "Device not found", 404)
    if device.store_id is not None and not ctx.can_access_store(device.store_id):
        raise AppError(CODE_NOT_FOUND, "Device not found", 404)

    before = {"status": device.status}
    device.status = "revoked"
    await db.execute(
        DeviceSession.__table__.update()
        .where(DeviceSession.device_id == device.id, DeviceSession.status == "active")
        .values(status="revoked", revoked_at=datetime.now(UTC))
    )
    await write_audit(
        db,
        action="device_revoked",
        entity_type="device",
        entity_id=str(device.id),
        tenant_id=ctx.tenant.id,
        store_id=device.store_id,
        user_id=ctx.user.id,
        before=before,
        after={"status": "revoked"},
        ip=client_ip(request),
    )
    await db.commit()


def build_me_response(ctx: AuthContext) -> MeResponse:
    return MeResponse(
        user=UserOut.model_validate(ctx.user),
        permissions=sorted(ctx.permissions),
        stores=[StoreOut.model_validate(s) for s in ctx.accessible_stores],
        device=DeviceOut.model_validate(ctx.device) if ctx.device else None,
    )
