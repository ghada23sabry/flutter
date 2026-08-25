"""Tests for product image upload and serving (P0-A fix)."""
import io

import pytest
from conftest import api_client, cleanup_tenant, login, make_tenant
from PIL import Image


def _make_test_image() -> bytes:
    img = Image.new("RGB", (100, 100), (200, 220, 255))
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=85)
    return buf.getvalue()


async def test_upload_and_fetch_image(tenant_creds):
    """Upload an image, then fetch it via GET — must return 200 with image bytes."""
    login_resp = await login(tenant_creds)
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    store_id = str(tenant_creds["store_id"])

    async with await api_client() as client:
        # Create product
        prod_resp = await client.post(
            "/products",
            params={"store_id": store_id},
            headers=headers,
            json={"name": "IMG-TEST", "unit": "pcs", "selling_price": "1.00"},
        )
        assert prod_resp.status_code == 201
        product_id = prod_resp.json()["id"]

        # Upload image
        img_bytes = _make_test_image()
        upload_resp = await client.post(
            f"/uploads/products/{product_id}/image",
            params={"store_id": store_id},
            headers=headers,
            files={"file": ("test.jpg", img_bytes, "image/jpeg")},
        )
        assert upload_resp.status_code == 200
        assert upload_resp.json()["status"] == "ok"

        # Verify product has image_url
        get_resp = await client.get(
            f"/products/{product_id}",
            params={"store_id": store_id},
            headers=headers,
        )
        assert get_resp.status_code == 200
        image_url = get_resp.json()["image_url"]
        assert image_url is not None
        assert product_id in image_url

        # Fetch image via GET — the main fix
        fetch_resp = await client.get(image_url, params={"store_id": store_id})
        assert fetch_resp.status_code == 200
        ct = fetch_resp.headers.get("content-type", "")
        assert "image" in ct, f"Expected image content-type, got: {ct}"
        assert len(fetch_resp.content) > 100, "Image body too small"


async def test_fetch_image_404_for_no_image(tenant_creds):
    """Product with no image should return 404 on GET image."""
    login_resp = await login(tenant_creds)
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    store_id = str(tenant_creds["store_id"])

    async with await api_client() as client:
        prod_resp = await client.post(
            "/products",
            params={"store_id": store_id},
            headers=headers,
            json={"name": "NO-IMG", "unit": "pcs", "selling_price": "1.00"},
        )
        product_id = prod_resp.json()["id"]

        fetch_resp = await client.get(
            f"/uploads/products/{product_id}/image",
            params={"store_id": store_id},
        )
        assert fetch_resp.status_code == 404


async def test_fetch_image_404_for_nonexistent_product(tenant_creds):
    """Nonexistent product UUID should return 404 on GET image."""
    login_resp = await login(tenant_creds)
    token = login_resp.json()["access_token"]
    store_id = str(tenant_creds["store_id"])

    async with await api_client() as client:
        fake_id = "00000000-0000-0000-0000-000000000000"
        fetch_resp = await client.get(
            f"/uploads/products/{fake_id}/image",
            params={"store_id": store_id},
        )
        assert fetch_resp.status_code == 404


async def test_upload_invalid_file_type(tenant_creds):
    """Uploading a non-image file must return 422."""
    login_resp = await login(tenant_creds)
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    store_id = str(tenant_creds["store_id"])

    async with await api_client() as client:
        prod_resp = await client.post(
            "/products",
            params={"store_id": store_id},
            headers=headers,
            json={"name": "TXT-TEST", "unit": "pcs", "selling_price": "1.00"},
        )
        product_id = prod_resp.json()["id"]

        upload_resp = await client.post(
            f"/uploads/products/{product_id}/image",
            params={"store_id": store_id},
            headers=headers,
            files={"file": ("test.txt", b"not an image", "text/plain")},
        )
        assert upload_resp.status_code == 422
