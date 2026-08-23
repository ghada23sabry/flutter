"""add product extended fields + sku_settings table

Revision ID: 0011
Revises: 0010
Create Date: 2026-08-23

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0011"
down_revision: str | None = "0010"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("products", sa.Column("variant", sa.String(length=120), nullable=True))
    op.add_column("products", sa.Column("model_name", sa.String(length=120), nullable=True))
    op.add_column("products", sa.Column("size", sa.String(length=60), nullable=True))
    op.add_column("products", sa.Column("weight", sa.String(length=60), nullable=True))
    op.add_column("products", sa.Column("volume", sa.String(length=60), nullable=True))

    op.create_table(
        "sku_settings",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "tenant_id",
            sa.Uuid(),
            sa.ForeignKey("tenants.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column(
            "store_id",
            sa.Uuid(),
            sa.ForeignKey("stores.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("prefix", sa.String(length=20), server_default="SKU", nullable=False),
        sa.Column("separator", sa.String(length=5), server_default="-", nullable=False),
        sa.Column("counter_length", sa.Integer(), server_default="5", nullable=False),
        sa.Column("next_counter", sa.Integer(), server_default="1", nullable=False),
        sa.Column("category_prefix", sa.Boolean(), server_default="false", nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.UniqueConstraint(
            "tenant_id", "store_id",
            name="uq_sku_settings_tenant_store",
        ),
    )


def downgrade() -> None:
    op.drop_table("sku_settings")
    op.drop_column("products", "volume")
    op.drop_column("products", "weight")
    op.drop_column("products", "size")
    op.drop_column("products", "model_name")
    op.drop_column("products", "variant")
