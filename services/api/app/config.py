from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "VisionStock AI"
    environment: str = "development"
    database_url: str = "postgresql+asyncpg://vs:vs@localhost:5432/visionstock"
    log_level: str = "INFO"
    log_dir: str = "logs"

    secret_key: str = ""
    jwt_algorithm: str = "HS256"
    token_issuer: str = "visionstock-api"
    access_token_expire_minutes: int = 15
    refresh_token_expire_days: int = 30

    near_expiry_days: int = 30

    # Single centralized confidence gate for AI vision (M4-A): any machine
    # detection below this score forces the scan session to NEEDS_REVIEW.
    ai_confidence_threshold: float = 0.70

    # M4-B: External vision provider (provider-agnostic).
    # "openai" | "google" | "" (falls back to mock for backward compat).
    ai_vision_provider: str = ""
    ai_vision_api_key: str = ""
    ai_vision_model: str = ""
    # Request timeout in seconds for external vision API calls.
    ai_vision_timeout: float = 30.0

    @property
    def is_production(self) -> bool:
        return self.environment == "production"


@lru_cache
def get_settings() -> Settings:
    settings = Settings()
    if settings.is_production and not settings.secret_key:
        raise RuntimeError("SECRET_KEY must be set in production")
    return settings
