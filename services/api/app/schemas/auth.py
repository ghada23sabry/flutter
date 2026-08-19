import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field


class DeviceInfo(BaseModel):
    device_uuid: str = Field(min_length=8, max_length=80)
    name: str | None = None
    platform: str | None = None
    model: str | None = None
    push_token: str | None = None


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=200)
    device: DeviceInfo | None = None


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=20, max_length=512)


class StoreOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    timezone: str
    currency: str


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: str
    name: str
    status: str


class DeviceOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    store_id: uuid.UUID | None
    device_uuid: str
    name: str | None
    platform: str | None
    model: str | None
    status: str
    last_seen_at: datetime | None


class LoginResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int
    user: UserOut
    permissions: list[str]
    stores: list[StoreOut]
    device: DeviceOut | None


class RefreshResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int


class MeResponse(BaseModel):
    user: UserOut
    permissions: list[str]
    stores: list[StoreOut]
    device: DeviceOut | None


class LogoutResponse(BaseModel):
    status: str = "ok"


class DeviceRegisterRequest(BaseModel):
    store_id: uuid.UUID
    device_uuid: str = Field(min_length=8, max_length=80)
    name: str | None = None
    platform: str | None = None
    model: str | None = None
    push_token: str | None = None


class RevokeResponse(BaseModel):
    status: str = "ok"
