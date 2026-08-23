"""add brand to products + visual recognition memory

Revision ID: 0010
Revises: 0009
Create Date: 2026-08-23

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0010"
down_revision: str | None = "0009"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("products", sa.Column("brand", sa.String(length=200), nullable=True))
    op.create_table(
        "product_visual_recognitions",
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
        sa.Column(
            "product_id",
            sa.Uuid(),
            sa.ForeignKey("products.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("normalized_name", sa.String(length=200), nullable=False),
        sa.Column("brand", sa.String(length=200), nullable=True),
        sa.Column(
            "source", sa.String(length=30), server_default="user_confirm", nullable=False
        ),
        sa.Column("hit_count", sa.Integer(), server_default="1", nullable=False),
        sa.Column("avg_confidence", sa.Numeric(5, 4), nullable=True),
        sa.Column(
            "created_by",
            sa.Uuid(),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
            index=True,
        ),
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
            "tenant_id", "store_id", "normalized_name",
            name="uq_product_visual_rec_tenant_store_name",
        ),
    )
    op.create_index(
        "ix_product_visual_rec_tenant_store",
        "product_visual_recognitions",
        ["tenant_id", "store_id"],
    )
    op.create_index(
        "ix_product_visual_rec_normalized_name",
        "product_visual_recognitions",
        ["normalized_name"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_product_visual_rec_normalized_name", table_name="product_visual_recognitions"
    )
    op.drop_index(
        "ix_product_visual_rec_tenant_store", table_name="product_visual_recognitions"
    )
    op.drop_table("product_visual_recognitions")
    op.drop_column("products", "brand")
