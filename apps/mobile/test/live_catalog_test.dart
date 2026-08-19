// M2.1 real catalog live integration — Flutter API layer → FastAPI → PostgreSQL.
//
// Proves the actual catalog mutations against the real backend (create / list /
// detail / update / search / SKU / barcode / supplier links / RBAC boundary).
//
// Not part of the default suite. Requires a live backend; run with:
//   flutter test --dart-define=LIVE_API=true \
//                --dart-define=API_BASE_URL=http://127.0.0.1:8000 \
//                test/live_catalog_test.dart
//
// No MockClient is used anywhere in this file — every request is real.
//
// Test data is deterministic (fixed SKU / supplier name) and idempotent: each
// run reuses an existing record if present instead of duplicating it. There is
// no product/supplier DELETE endpoint, so cleanup marks records inactive
// (excluded from the default active list) — the live DB is the dev DB only.
//
// RBAC: `scripts/provision_rbac_viewer.py` must be run once so that
// viewer@acme.com exists with ONLY `products.view` (no products.manage).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:visionstock_mobile/core/api/auth_api.dart';
import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/barcode/barcode.dart';
import 'package:visionstock_mobile/core/config.dart';
import 'package:visionstock_mobile/core/models/auth_models.dart';
import 'package:visionstock_mobile/core/session.dart';
import 'package:visionstock_mobile/core/session_store.dart';
import 'package:visionstock_mobile/features/catalog/data/catalog_api.dart';
import 'package:visionstock_mobile/features/catalog/data/catalog_models.dart';

const bool _live = bool.fromEnvironment('LIVE_API', defaultValue: false);

const String _ownerEmail =
    String.fromEnvironment('TEST_USER_EMAIL', defaultValue: 'owner@acme.com');
const String _ownerPassword =
    String.fromEnvironment('TEST_USER_PASSWORD', defaultValue: 'Test1234!');
const String _viewerEmail =
    String.fromEnvironment('TEST_VIEWER_EMAIL', defaultValue: 'viewer@acme.com');
const String _viewerPassword =
    String.fromEnvironment('TEST_VIEWER_PASSWORD', defaultValue: 'Test1234!');

/// Base URL: env override → compile-time dart-define → AppConfig default.
String get _baseUrl => Platform.environment['API_BASE_URL'] ?? AppConfig.apiBaseUrl;

final bool _skip = !_live;

// Deterministic identities (idempotent across runs).
const String _productSku = 'M21-QA-PROD-001';
const String _productBarcode = '2100000000123';
const String _baseName = 'M2.1 QA Product';
const String _editedName = 'M2.1 QA Product (edited)';
const double _basePrice = 19.99;
const double _editedPrice = 29.99;
const String _supplierName = 'M2.1 QA Supplier';

/// Build a real [http.Client] even inside `flutter test`.
///
/// `TestWidgetsFlutterBinding` installs a global mock `HttpOverrides` that
/// turns every `HttpClient()` into a 400-returning stub. Creating the client
/// while `HttpOverrides.global` is temporarily nulled yields the real one;
/// it stays real for all later requests regardless of the restored global.
http.Client _createRealHttpClient() {
  final previous = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return http.Client();
  } finally {
    HttpOverrides.global = previous;
  }
}

ApiClient _createRealApiClient() =>
    ApiClient(baseUrl: _baseUrl, client: _createRealHttpClient());

Future<void> _waitForBackend() async {
  final client = _createRealHttpClient();
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final response = await client.get(Uri.parse('$_baseUrl/health'));
      if (response.statusCode == 200) {
        client.close();
        return;
      }
    } catch (_) {
      // backend still starting
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  client.close();
  fail('Backend not reachable at $_baseUrl. Start uvicorn first.');
}

Future<SessionController> _login(String email, String password) async {
  final apiClient = _createRealApiClient();
  final controller = SessionController(storage: MemorySessionStorage(), api: AuthApi(apiClient));
  await controller.login(email: email, password: password);
  return controller;
}

/// Create, or reset an existing record to, the deterministic baseline product.
/// Idempotent: repeated runs never create uncontrolled duplicates.
Future<Product> _ensureProduct(CatalogApi api, StoreInfo store) async {
  var product = await api.lookupBySku(store: store, sku: _productSku);
  if (product == null) {
    product = await api.createProduct(
      store: store,
      input: ProductInput(
        name: _baseName,
        sku: _productSku,
        barcode: _productBarcode,
        unit: 'pcs',
        costPrice: 9.99,
        sellingPrice: _basePrice,
        reorderPoint: 5,
        reorderQuantity: 20,
      ),
    );
  } else if (product.status != 'active' || product.name != _baseName || product.sellingPrice != _basePrice) {
    product = await api.updateProduct(
      store: store,
      id: product.id,
      update: ProductUpdate(
        status: 'active',
        name: _baseName,
        barcode: _productBarcode,
        costPrice: 9.99,
        sellingPrice: _basePrice,
        reorderPoint: 5,
        reorderQuantity: 20,
      ),
    );
  }
  return product;
}

/// Create, or reuse any existing record for, the deterministic supplier.
/// Reuses an existing supplier (active or inactive) and reactivates it to the
/// baseline instead of duplicating; any older extras are set inactive (cleanup).
Future<Supplier> _ensureSupplier(CatalogApi api) async {
  final page = await api.listSuppliers(q: _supplierName, pageSize: 100);
  for (final extra in page.items.skip(1)) {
    await api.updateSupplier(id: extra.id, update: SupplierUpdate(status: 'inactive'));
  }
  if (page.items.isNotEmpty) {
    return api.updateSupplier(
      id: page.items.first.id,
      update: SupplierUpdate(status: 'active', contactName: 'M2.1 QA Contact', phone: '+1 555 0001'),
    );
  }
  return api.createSupplier(
    input: SupplierInput(
      name: _supplierName,
      contactName: 'M2.1 QA Contact',
      phone: '+1 555 0001',
      email: 'qa.supplier@test.dev',
    ),
  );
}

void main() {
  setUpAll(() async {
    if (_live) await _waitForBackend();
  });

  test(
    'product live flow: list → create/ensure → appears → details → edit → search → sku → barcode',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final api = CatalogApi(controller.apiClient);

      final created = await _ensureProduct(api, store);
      expect(created.sku, _productSku);
      expect(created.barcode, _productBarcode);
      expect(created.name, _baseName);
      expect(created.sellingPrice, _basePrice);
      expect(created.status, 'active');

      // Product appears in the (active) list.
      final listed = await api.listProducts(store: store, q: _productSku, status: 'active');
      expect(listed.items.any((p) => p.id == created.id), isTrue, reason: 'product must appear in list');

      // Product details.
      final detail = await api.getProduct(store: store, id: created.id);
      expect(detail.id, created.id);
      expect(detail.name, _baseName);
      expect(detail.unit, 'pcs');

      // Edit product.
      final updated = await api.updateProduct(
        store: store,
        id: created.id,
        update: ProductUpdate(
          name: _editedName,
          description: 'M2.1 live edit',
          sellingPrice: _editedPrice,
        ),
      );
      expect(updated.name, _editedName);
      expect(updated.description, 'M2.1 live edit');
      expect(updated.sellingPrice, _editedPrice);

      // Search by edited name finds it.
      final searched = await api.listProducts(store: store, q: _editedName);
      expect(searched.items.any((p) => p.id == created.id), isTrue, reason: 'search must find updated product');

      // SKU lookup.
      final bySku = await api.lookupBySku(store: store, sku: _productSku);
      expect(bySku, isNotNull);
      expect(bySku!.id, created.id);
      expect(bySku.name, _editedName);

      // Barcode lookup with non-normalized input proves the shared normalize
      // contract (Camera → Decode → normalizeBarcode → Catalog API → Product).
      final byBarcode = await api.lookupByBarcode(store: store, barcode: '  2100000000123  ');
      expect(byBarcode, isNotNull);
      expect(byBarcode!.id, created.id);
      expect(byBarcode.name, _editedName);
      expect(normalizeBarcode('  2100000000123  '), _productBarcode);

      // Cleanup: mark inactive so it leaves the active list (no DELETE endpoint).
      final inactive = await api.updateProduct(store: store, id: created.id, update: ProductUpdate(status: 'inactive'));
      expect(inactive.status, 'inactive');
      final afterCleanup = await api.listProducts(store: store, q: _productSku, status: 'active');
      expect(afterCleanup.items.any((p) => p.id == created.id), isFalse, reason: 'cleaned-up product must not appear as active');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'supplier live flow: list → ensure → details → edit → link → verify → unlink',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final api = CatalogApi(controller.apiClient);

      final product = await _ensureProduct(api, store);
      final supplier = await _ensureSupplier(api);
      expect(supplier.name, _supplierName);
      expect(supplier.status, 'active');

      // Supplier details.
      final detail = await api.getSupplier(id: supplier.id);
      expect(detail.id, supplier.id);

      // Edit supplier.
      final updated = await api.updateSupplier(
        id: supplier.id,
        update: SupplierUpdate(contactName: 'M2.1 QA Contact (updated)', notes: 'M2.1 live edit'),
      );
      expect(updated.contactName, 'M2.1 QA Contact (updated)');
      expect(updated.notes, 'M2.1 live edit');

      // Link supplier → product.
      final link = await api.linkProductToSupplier(
        store: store,
        supplierId: supplier.id,
        productId: product.id,
        supplierSku: 'M21-SUP-SKU',
        supplierCost: 12.5,
        leadTimeDays: 3,
        isPreferred: true,
      );
      expect(link.supplierId, supplier.id);
      expect(link.productId, product.id);
      expect(link.supplierSku, 'M21-SUP-SKU');
      expect(link.supplierCost, 12.5);

      // Verify relationship from both directions.
      final supplierProducts = await api.getSupplierProducts(supplierId: supplier.id);
      expect(supplierProducts.any((l) => l.productId == product.id), isTrue, reason: 'supplier must list the product');
      final productSuppliers = await api.getProductSuppliers(store: store, productId: product.id);
      expect(productSuppliers.any((l) => l.supplierId == supplier.id), isTrue, reason: 'product must list the supplier');

      // Edit the link.
      final editedLink = await api.updateSupplierProductLink(
        store: store,
        supplierId: supplier.id,
        productId: product.id,
        supplierSku: 'M21-SUP-SKU-2',
        supplierCost: 11.25,
        isPreferred: false,
      );
      expect(editedLink.supplierSku, 'M21-SUP-SKU-2');
      expect(editedLink.supplierCost, 11.25);
      expect(editedLink.isPreferred, isFalse);

      // Unlink and verify it's gone.
      await api.unlinkProduct(store: store, supplierId: supplier.id, productId: product.id);
      final afterUnlink = await api.getSupplierProducts(supplierId: supplier.id);
      expect(afterUnlink.any((l) => l.productId == product.id), isFalse, reason: 'link must be removed');

      // Cleanup: mark both inactive.
      await api.updateSupplier(id: supplier.id, update: SupplierUpdate(status: 'inactive'));
      await api.updateProduct(store: store, id: product.id, update: ProductUpdate(status: 'inactive'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'rbac live: products.view allows GET, products.manage blocks CREATE/UPDATE with 403',
    skip: _skip,
    () async {
      final controller = await _login(_viewerEmail, _viewerPassword);
      expect(controller.current!.permissions, contains('products.view'));
      expect(controller.current!.permissions, isNot(contains('products.manage')));

      final store = controller.selectedStore!;
      final api = CatalogApi(controller.apiClient);

      // GET products → allowed.
      final page = await api.listProducts(store: store, status: 'active', pageSize: 5);
      expect(page.items, isA<List<Product>>());

      // CREATE product → 403 FORBIDDEN.
      await expectLater(
        api.createProduct(
          store: store,
          input: ProductInput(name: 'M21-QA-RBAC-DENIED', sku: 'M21-QA-RBAC-1', unit: 'pcs', sellingPrice: 1),
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.code, 'code', 'FORBIDDEN'),
        ),
      );

      // UPDATE product (readable but not manageable) → 403 FORBIDDEN.
      // The deterministic product always exists: the product live flow above
      // creates it, and SKU lookup is a products.view (allowed) read.
      final product = await api.lookupBySku(store: store, sku: _productSku);
      expect(product, isNotNull, reason: 'deterministic product must exist (product live flow runs first)');
      await expectLater(
        api.updateProduct(store: store, id: product!.id, update: ProductUpdate(name: 'M21-QA-RBAC-DENIED')),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.code, 'code', 'FORBIDDEN'),
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
