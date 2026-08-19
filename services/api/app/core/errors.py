import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

logger = logging.getLogger(__name__)

CODE_UNAUTHORIZED = "UNAUTHORIZED"
CODE_INVALID_CREDENTIALS = "INVALID_CREDENTIALS"
CODE_ACCOUNT_DISABLED = "ACCOUNT_DISABLED"
CODE_DEVICE_REVOKED = "DEVICE_REVOKED"
CODE_SESSION_EXPIRED = "SESSION_EXPIRED"
CODE_FORBIDDEN = "FORBIDDEN"
CODE_NOT_FOUND = "NOT_FOUND"
CODE_CONFLICT = "CONFLICT"
CODE_VALIDATION_ERROR = "VALIDATION_ERROR"
CODE_INTERNAL_ERROR = "INTERNAL_ERROR"


class AppError(Exception):
    def __init__(
        self,
        code: str,
        message: str,
        status_code: int = 400,
        details: dict | list | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code
        self.details = details


def error_body(code: str, message: str, details: dict | list | None = None) -> dict:
    return {"detail": {"code": code, "message": message, "details": details}}


def _safe_validation_details(errors: list) -> list:
    """Make Pydantic `errors()` JSON-safe.

    Pydantic v2 embeds the raw exception instance (e.g. a `ValueError` raised by
    a `model_validator`) in `ctx["error"]`, which is not JSON-serializable.
    """
    clean = []
    for err in errors:
        item = dict(err)
        ctx = item.get("ctx")
        if isinstance(ctx, dict):
            item["ctx"] = {
                k: (str(v) if not isinstance(v, (str, int, float, bool, type(None))) else v) for k, v in ctx.items()
            }
        clean.append(item)
    return clean


def register_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(AppError)
    async def _app_error_handler(request: Request, exc: AppError):
        return JSONResponse(
            status_code=exc.status_code,
            content=error_body(exc.code, exc.message, exc.details),
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http_error_handler(request: Request, exc: StarletteHTTPException):
        code = {
            401: CODE_UNAUTHORIZED,
            403: CODE_FORBIDDEN,
            404: CODE_NOT_FOUND,
            409: CODE_CONFLICT,
        }.get(exc.status_code, CODE_VALIDATION_ERROR)
        message = str(exc.detail) if isinstance(exc.detail, str) else "Request failed"
        return JSONResponse(
            status_code=exc.status_code,
            content=error_body(code, message),
        )

    @app.exception_handler(RequestValidationError)
    async def _validation_error_handler(request: Request, exc: RequestValidationError):
        return JSONResponse(
            status_code=422,
            content=error_body(
                CODE_VALIDATION_ERROR,
                "Request validation failed",
                _safe_validation_details(exc.errors()),
            ),
        )

    @app.exception_handler(Exception)
    async def _unhandled_error_handler(request: Request, exc: Exception):
        logger.exception("unhandled error on %s %s", request.method, request.url.path)
        return JSONResponse(
            status_code=500,
            content=error_body(CODE_INTERNAL_ERROR, "An internal error occurred"),
        )
