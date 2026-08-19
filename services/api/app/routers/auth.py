from typing import Annotated

from fastapi import APIRouter, Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import get_db
from app.core.security import AuthContext, get_auth_context
from app.schemas.auth import (
    LoginRequest,
    LoginResponse,
    LogoutResponse,
    MeResponse,
    RefreshRequest,
    RefreshResponse,
)
from app.services.auth_service import build_me_response, login, logout, refresh

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/login", response_model=LoginResponse)
async def login_endpoint(body: LoginRequest, request: Request, db: Annotated[AsyncSession, Depends(get_db)]):
    result = await login(
        db,
        request,
        email=body.email,
        password=body.password,
        device_info=body.device,
    )
    return result


@router.post("/refresh", response_model=RefreshResponse)
async def refresh_endpoint(body: RefreshRequest, request: Request, db: Annotated[AsyncSession, Depends(get_db)]):
    access_token, refresh_token, expires_in = await refresh(db, request, body.refresh_token)
    return RefreshResponse(access_token=access_token, refresh_token=refresh_token, expires_in=expires_in)


@router.post("/logout", response_model=LogoutResponse)
async def logout_endpoint(
    request: Request,
    ctx: Annotated[AuthContext, Depends(get_auth_context)],
    db: Annotated[AsyncSession, Depends(get_db)],
):
    await logout(db, request, ctx)
    return LogoutResponse()


@router.get("/me", response_model=MeResponse)
async def me_endpoint(ctx: Annotated[AuthContext, Depends(get_auth_context)]):
    return build_me_response(ctx)
