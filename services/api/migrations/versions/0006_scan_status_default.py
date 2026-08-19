"""align scan_sessions.status default with the M4-A.3 lifecycle vocabulary

Revision ID: 0006
Revises: 0005
Create Date: 2026-08-13

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0006"
down_revision: str | None = "0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.alter_column(
        "scan_sessions",
        "status",
        server_default=sa.text("'processing'"),
        existing_server_default=sa.text("'active'"),
        existing_type=sa.String(20),
        existing_nullable=False,
    )


def downgrade() -> None:
    op.alter_column(
        "scan_sessions",
        "status",
        server_default=sa.text("'active'"),
        existing_server_default=sa.text("'processing'"),
        existing_type=sa.String(20),
        existing_nullable=False,
    )
