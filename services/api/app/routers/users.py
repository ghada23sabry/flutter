from typing import Annotated

from fastapi import APIRouter, Depends

from app.core.security import AuthContext, get_auth_context
from app.schemas.auth import UserOut

router = APIRouter(prefix="/users", tags=["users"])


@router.get("/me", response_model=UserOut)
async def me(ctx: Annotated[AuthContext, Depends(get_auth_context)]):
    return UserOut.model_validate(ctx.user)
