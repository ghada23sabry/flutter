"""catalog schema: categories, products, suppliers

Revision ID: 0003
Revises: 0002
Create Date: 2026-08-11

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

PERMISSIONS = [
    ("categories.view", "catalog", "View product categories"),
    ("categories.manage", "catalog", "Create and manage product categories"),
    ("suppliers.view", "catalog", "View suppliers"),
    ("suppliers.manage", "catalog", "Create and manage suppliers"),
]

SYSTEM_ROLES = ["owner", "admin"]


def upgrade() -> None:
    op.create_table(
        "categories",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("store_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("stores.id", ondelete="CASCADE"), nullable=False),
        sa.Column("parent_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("categories.id", ondelete="SET NULL"), nullable=True),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("code", sa.String(40), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("store_id", "code", name="uq_categories_store_code"),
    )
    op.create_index("ix_categories_tenant_id", "categories", ["tenant_id"])
    op.create_index("ix_categories_store_id", "categories", ["store_id"])
    op.create_index("ix_categories_store_name", "categories", ["store_id", "name"])

    op.create_table(
        "products",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("store_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("stores.id", ondelete="CASCADE"), nullable=False),
        sa.Column("category_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("categories.id", ondelete="SET NULL"), nullable=True),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("sku", sa.String(64), nullable=False),
        sa.Column("barcode", sa.String(64), nullable=True),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("unit", sa.String(20), nullable=False),
        sa.Column("cost_price", sa.Numeric(14, 2), nullable=False, server_default=sa.text("0")),
        sa.Column("selling_price", sa.Numeric(14, 2), nullable=False),
        sa.Column("reorder_point", sa.Numeric(12, 3), nullable=False, server_default=sa.text("0")),
        sa.Column("reorder_quantity", sa.Numeric(12, 3), nullable=False, server_default=sa.text("0")),
        sa.Column("expiry_tracking_enabled", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("image_url", sa.String(500), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("store_id", "sku", name="uq_products_store_sku"),
    )
    op.create_index("ix_products_tenant_id", "products", ["tenant_id"])
    op.create_index("ix_products_store_id", "products", ["store_id"])
    op.create_index("ix_products_category_id", "products", ["category_id"])
    op.create_index("uq_products_store_barcode", "products", ["store_id", "barcode"], unique=True, postgresql_where=sa.text("barcode IS NOT NULL"))
    op.create_index("ix_products_store_name", "products", ["store_id", "name"])

    op.create_table(
        "product_visual_profiles",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("store_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("stores.id", ondelete="CASCADE"), nullable=False),
        sa.Column("product_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("products.id", ondelete="CASCADE"), nullable=False),
        sa.Column("label", sa.String(120), nullable=False),
        sa.Column("reference_image_url", sa.String(500), nullable=True),
        sa.Column("model_version", sa.String(60), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="draft"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_product_visual_profiles_tenant_id", "product_visual_profiles", ["tenant_id"])
    op.create_index("ix_product_visual_profiles_store_id", "product_visual_profiles", ["store_id"])
    op.create_index("ix_product_visual_profiles_product_id", "product_visual_profiles", ["product_id"])

    op.create_table(
        "suppliers",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("contact_name", sa.String(120), nullable=True),
        sa.Column("phone", sa.String(32), nullable=True),
        sa.Column("email", sa.String(255), nullable=True),
        sa.Column("address", sa.Text(), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_suppliers_tenant_id", "suppliers", ["tenant_id"])

    op.create_table(
        "supplier_products",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("supplier_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("suppliers.id", ondelete="CASCADE"), nullable=False),
        sa.Column("product_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("products.id", ondelete="CASCADE"), nullable=False),
        sa.Column("supplier_sku", sa.String(64), nullable=True),
        sa.Column("supplier_cost", sa.Numeric(14, 2), nullable=True),
        sa.Column("lead_time_days", sa.Integer(), nullable=True),
        sa.Column("is_preferred", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("supplier_id", "product_id", name="uq_supplier_products"),
    )
    op.create_index("ix_supplier_products_tenant_id", "supplier_products", ["tenant_id"])
    op.create_index("ix_supplier_products_supplier_id", "supplier_products", ["supplier_id"])
    op.create_index("ix_supplier_products_product_id", "supplier_products", ["product_id"])

    _seed_catalog_permissions()


def _seed_catalog_permissions() -> None:
    conn = op.get_bind()
    permission_ids: dict[str, str] = {}
    for code, domain, description in PERMISSIONS:
        row = conn.execute(
            sa.text(
                "INSERT INTO permissions (id, code, domain, description) "
                "VALUES (gen_random_uuid(), :code, :domain, :description) "
                "ON CONFLICT (code) DO NOTHING RETURNING id"
            ),
            {"code": code, "domain": domain, "description": description},
        ).first()
        if row is None:
            row = conn.execute(sa.text("SELECT id FROM permissions WHERE code = :code"), {"code": code}).first()
        permission_ids[code] = row[0]

    for role_name in SYSTEM_ROLES:
        role_id = conn.execute(
            sa.text("SELECT id FROM roles WHERE tenant_id IS NULL AND name = :name"), {"name": role_name}
        ).first()
        if role_id is None:
            continue
        for perm_code in PERMISSIONS:
            conn.execute(
                sa.text(
                    "INSERT INTO role_permissions (role_id, permission_id) "
                    "VALUES (:role_id, :perm_id) "
                    "ON CONFLICT (role_id, permission_id) DO NOTHING"
                ),
                {"role_id": role_id[0], "perm_id": permission_ids[perm_code[0]]},
            )


def downgrade() -> None:
    op.drop_index("ix_supplier_products_product_id", table_name="supplier_products")
    op.drop_index("ix_supplier_products_supplier_id", table_name="supplier_products")
    op.drop_index("ix_supplier_products_tenant_id", table_name="supplier_products")
    op.drop_table("supplier_products")
    op.drop_index("ix_suppliers_tenant_id", table_name="suppliers")
    op.drop_table("suppliers")
    op.drop_index("ix_product_visual_profiles_product_id", table_name="product_visual_profiles")
    op.drop_index("ix_product_visual_profiles_store_id", table_name="product_visual_profiles")
    op.drop_index("ix_product_visual_profiles_tenant_id", table_name="product_visual_profiles")
    op.drop_table("product_visual_profiles")
    op.drop_index("ix_products_store_name", table_name="products")
    op.drop_index("uq_products_store_barcode", table_name="products")
    op.drop_index("ix_products_category_id", table_name="products")
    op.drop_index("ix_products_store_id", table_name="products")
    op.drop_index("ix_products_tenant_id", table_name="products")
    op.drop_table("products")
    op.drop_index("ix_categories_store_name", table_name="categories")
    op.drop_index("ix_categories_store_id", table_name="categories")
    op.drop_index("ix_categories_tenant_id", table_name="categories")
    op.drop_table("categories")

    conn = op.get_bind()
    for code, _, _ in PERMISSIONS:
        conn.execute(
            sa.text("DELETE FROM role_permissions WHERE permission_id = (SELECT id FROM permissions WHERE code = :code)"),
            {"code": code},
        )
        conn.execute(sa.text("DELETE FROM permissions WHERE code = :code"), {"code": code})
