"""Dev-only provisioning for the live RBAC verification user.

Creates a system `viewer` role holding ONLY `products.view`, a `viewer@acme.com`
user in the `acme` tenant, and a store-scoped role grant to the `Downtown`
store. Used by `test/live_catalog_test.dart` to prove the products.view /
products.manage permission boundary. Idempotent.

Usage (cwd = services/api, .env present):
  python -m scripts.provision_rbac_viewer
  python -m scripts.provision_rbac_viewer --email viewer@example.com --password secret

This is developer tooling, not a product feature, and never runs in production.
"""
import argparse
import asyncio
import os
import sys

from sqlalchemy import select

from app.core.db import SessionLocal
from app.core.security import hash_password
from app.models import Permission, Role, RolePermission, Store, Tenant, User, UserRole

VIEWER_PERMISSIONS = ["products.view"]


async def provision(*, email: str, password: str) -> int:
    async with SessionLocal() as db:
        tenant = (
            await db.execute(select(Tenant).where(Tenant.slug == os.environ.get("TENANT_SLUG", "acme")))
        ).scalar_one_or_none()
        if tenant is None:
            print("error: tenant 'acme' not found", file=sys.stderr)
            return 1

        store = (
            await db.execute(
                select(Store).where(Store.tenant_id == tenant.id, Store.name == os.environ.get("STORE_NAME", "Downtown"))
            )
        ).scalar_one_or_none()
        if store is None:
            print("error: store 'Downtown' not found for tenant", file=sys.stderr)
            return 1

        role = (
            await db.execute(select(Role).where(Role.tenant_id.is_(None), Role.name == "viewer", Role.is_system.is_(True)))
        ).scalar_one_or_none()
        if role is None:
            role = Role(name="viewer", description="System viewer role (read-only products)", is_system=True)
            db.add(role)
            await db.flush()

        for code in VIEWER_PERMISSIONS:
            perm = (await db.execute(select(Permission).where(Permission.code == code))).scalar_one_or_none()
            if perm is None:
                print(f"error: permission {code!r} not seeded (run alembic upgrade head first)", file=sys.stderr)
                return 1
            link = (
                await db.execute(
                    select(RolePermission).where(
                        RolePermission.role_id == role.id,
                        RolePermission.permission_id == perm.id,
                    )
                )
            ).scalar_one_or_none()
            if link is None:
                db.add(RolePermission(role_id=role.id, permission_id=perm.id))

        user = (await db.execute(select(User).where(User.email == email))).scalar_one_or_none()
        if user is None:
            user = User(
                tenant_id=tenant.id,
                email=email,
                name="Viewer",
                password_hash=hash_password(password),
                status="active",
            )
            db.add(user)
            await db.flush()
        elif user.tenant_id != tenant.id:
            print(f"error: email {email} belongs to another tenant", file=sys.stderr)
            return 1

        grant = (
            await db.execute(
                select(UserRole).where(UserRole.user_id == user.id, UserRole.role_id == role.id)
            )
        ).scalar_one_or_none()
        if grant is None:
            db.add(UserRole(user_id=user.id, role_id=role.id, store_id=store.id))

        await db.commit()

    print(f"role=viewer permissions={VIEWER_PERMISSIONS}")
    print(f"user={email} tenant={tenant.slug} store={store.name} store_id={store.id}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="provision-rbac-viewer", description="Provision the RBAC viewer test user")
    parser.add_argument("--email", default="viewer@acme.com")
    parser.add_argument("--password", default="Test1234!")
    args = parser.parse_args()
    return asyncio.run(provision(email=args.email, password=args.password))


if __name__ == "__main__":
    sys.exit(main())
