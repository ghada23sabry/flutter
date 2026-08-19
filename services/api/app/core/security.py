import hashlib
import secrets
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Annotated

import bcrypt
import jwt
from fastapi import Depends, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.core.db import get_db
from app.core.errors import (
    CODE_ACCOUNT_DISABLED,
    CODE_DEVICE_REVOKED,
    CODE_FORBIDDEN,
    CODE_SESSION_EXPIRED,
    CODE_UNAUTHORIZED,
    AppError,
)
from app.models import Device, DeviceSession, Permission, Role, RolePermission, Store, Tenant, User, UserRole

_BCRYPT_ROUNDS = 12


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt(rounds=_BCRYPT_ROUNDS)).decode("utf-8")


def verify_password(plain: str, hashed: str) -> bool:
    try:
        return bcrypt.checkpw(plain.encode("utf-8"), hashed.encode("utf-8"))
    except ValueError:
        return False


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def generate_refresh_token() -> str:
    return secrets.token_urlsafe(48)


def create_access_token(*, user_id: uuid.UUID, tenant_id: uuid.UUID, session_id: uuid.UUID, device_id: uuid.UUID | None) -> str:
    settings = get_settings()
    now = datetime.now(UTC)
    payload = {
        "sub": str(user_id),
        "tid": str(tenant_id),
        "sid": str(session_id),
        "dev": str(device_id) if device_id else None,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=settings.access_token_expire_minutes)).timestamp()),
        "iss": settings.token_issuer,
        "jti": str(uuid.uuid4()),
    }
    return jwt.encode(payload, settings.secret_key, algorithm=settings.jwt_algorithm)


def decode_access_token(token: str) -> dict:
    settings = get_settings()
    try:
        return jwt.decode(
            token,
            settings.secret_key,
            algorithms=[settings.jwt_algorithm],
            issuer=settings.token_issuer,
            options={"verify_aud": False},
        )
    except jwt.ExpiredSignatureError as exc:
        raise AppError(CODE_SESSION_EXPIRED, "Access token has expired", 401) from exc
    except jwt.InvalidTokenError as exc:
        raise AppError(CODE_UNAUTHORIZED, "Invalid access token", 401) from exc


def client_ip(request: Request) -> str | None:
    return request.client.host if request.client else None


@dataclass
class AuthContext:
    user: User
    tenant: Tenant
    device: Device | None
    device_session: DeviceSession
    permissions: set[str] = field(default_factory=set)
    accessible_stores: list[Store] = field(default_factory=list)

    def can_access_store(self, store_id: uuid.UUID) -> bool:
        return any(store.id == store_id for store in self.accessible_stores)


async def get_auth_context(
    request: Request,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> AuthContext:
    authorization = request.headers.get("Authorization", "")
    if not authorization.startswith("Bearer "):
        raise AppError(CODE_UNAUTHORIZED, "Authentication required", 401)
    token = authorization[len("Bearer ") :].strip()
    payload = decode_access_token(token)

    session_id = payload.get("sid")
    if not session_id:
        raise AppError(CODE_UNAUTHORIZED, "Invalid access token", 401)

    session_row = (
        await db.execute(
            select(DeviceSession).where(DeviceSession.id == session_id, DeviceSession.status == "active")
        )
    ).scalar_one_or_none()
    if session_row is None:
        raise AppError(CODE_SESSION_EXPIRED, "Session is no longer active", 401)

    user = await db.get(User, uuid.UUID(payload["sub"]))
    if user is None:
        raise AppError(CODE_UNAUTHORIZED, "User not found", 401)
    if user.status != "active":
        raise AppError(CODE_ACCOUNT_DISABLED, "Account is disabled", 401)

    tenant = await db.get(Tenant, uuid.UUID(payload["tid"]))
    if tenant is None or tenant.status != "active":
        raise AppError(CODE_UNAUTHORIZED, "Tenant not active", 401)
    if session_row.tenant_id != tenant.id or session_row.user_id != user.id:
        raise AppError(CODE_UNAUTHORIZED, "Session tenant mismatch", 401)

    device = None
    if session_row.device_id is not None:
        device = await db.get(Device, session_row.device_id)
        if device is None or device.status != "active":
            raise AppError(CODE_DEVICE_REVOKED, "Device is revoked or locked", 401)

    roles = (
        await db.execute(
            select(Role).join(UserRole, UserRole.role_id == Role.id).where(UserRole.user_id == user.id)
        )
    ).scalars().all()

    permissions: set[str] = set()
    if roles:
        permissions = set(
            (
                await db.execute(
                    select(Permission.code)
                    .join(RolePermission, RolePermission.permission_id == Permission.id)
                    .where(RolePermission.role_id.in_([r.id for r in roles]))
                )
            ).scalars().all()
        )

    user_roles = (await db.execute(select(UserRole).where(UserRole.user_id == user.id))).scalars().all()
    tenant_stores = (await db.execute(select(Store).where(Store.tenant_id == tenant.id))).scalars().all()
    has_tenant_wide = any(ur.store_id is None for ur in user_roles)
    if has_tenant_wide:
        accessible_stores = list(tenant_stores)
    else:
        store_ids = {ur.store_id for ur in user_roles if ur.store_id is not None}
        accessible_stores = [s for s in tenant_stores if s.id in store_ids]

    ctx = AuthContext(
        user=user,
        tenant=tenant,
        device=device,
        device_session=session_row,
        permissions=permissions,
        accessible_stores=accessible_stores,
    )
    request.state.auth = ctx
    return ctx


def require_permission(code: str):
    async def _dependency(ctx: Annotated[AuthContext, Depends(get_auth_context)]) -> AuthContext:
        if code not in ctx.permissions:
            raise AppError(CODE_FORBIDDEN, "Insufficient permissions", 403)
        return ctx

    return _dependency
