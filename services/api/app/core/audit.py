from sqlalchemy.ext.asyncio import AsyncSession

from app.models.audit import AuditLog


async def write_audit(
    db: AsyncSession,
    *,
    action: str,
    entity_type: str | None = None,
    entity_id: str | None = None,
    tenant_id: str | None = None,
    store_id: str | None = None,
    user_id: str | None = None,
    before: dict | None = None,
    after: dict | None = None,
    ip: str | None = None,
) -> None:
    db.add(
        AuditLog(
            tenant_id=tenant_id,
            store_id=store_id,
            user_id=user_id,
            action=action,
            entity_type=entity_type,
            entity_id=entity_id,
            before=before,
            after=after,
            ip=ip,
        )
    )
