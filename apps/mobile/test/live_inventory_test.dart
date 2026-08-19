// M3 inventory live integration — Flutter API layer → FastAPI → PostgreSQL.
//
// Proves the actual inventory mutations against the real backend (stock list /
// summary / detail, opening stock, delta-based adjustment, movements, zones,
// shelves, shelf-product mapping, expiry batches, and the RBAC boundary).
//
// Not part of the default suite. Requires a live backend; run with:
//   flutter test --dart-define=LIVE_API=true \
//                --dart-define=API_BASE_URL=http://127.0.0.1:8000 \
//                test/live_inventory_test.dart
//
// No MockClient is used anywhere in this file — every request is real.
//
// Test data is deterministic (fixed SKU / zone / shelf codes) and idempotent:
// each run reuses an existing record instead of duplicating it. Stock quantity
// is normalized to a fixed target on every run via a delta adjustment, so the
// suite is repeatable regardless of prior state. There is no stock DELETE
// endpoint; the expiry batch created here is deleted as its own cleanup, and
// the product is marked inactive at the end (no product DELETE either).
//
// RBAC: `scripts/provision_rbac_inventory_viewer.py` must be run once so that
// inv-viewer@acme.com exists with ONLY `inventory.view`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:visionstock_mobile/core/api/auth_api.dart';
import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/config.dart';
import 'package:visionstock_mobile/core/models/auth_models.dart';
import 'package:visionstock_mobile/core/session.dart';
import 'package:visionstock_mobile/core/session_store.dart';
import 'package:visionstock_mobile/features/catalog/data/catalog_api.dart';
import 'package:visionstock_mobile/features/catalog/data/catalog_models.dart';
import 'package:visionstock_mobile/features/inventory/data/inventory_api.dart';
import 'package:visionstock_mobile/features/inventory/data/inventory_models.dart';

const bool _live = bool.fromEnvironment('LIVE_API', defaultValue: false);

const String _ownerEmail =
    String.fromEnvironment('TEST_USER_EMAIL', defaultValue: 'owner@acme.com');
const String _ownerPassword =
    String.fromEnvironment('TEST_USER_PASSWORD', defaultValue: 'Test1234!');
const String _viewerEmail =
    String.fromEnvironment('TEST_VIEWER_EMAIL', defaultValue: 'inv-viewer@acme.com');
const String _viewerPassword =
    String.fromEnvironment('TEST_VIEWER_PASSWORD', defaultValue: 'Test1234!');

/// Base URL: env override → compile-time dart-define → AppConfig default.
String get _baseUrl => Platform.environment['API_BASE_URL'] ?? AppConfig.apiBaseUrl;

final bool _skip = !_live;

// Deterministic identities (idempotent across runs).
const String _productSku = 'M3-QA-PROD-001';
const String _productBarcode = '2300000000123';
const String _baseName = 'M3 QA Product';
const String _zoneCode = 'M3-QA-ZONE';
const String _zoneName = 'M3 QA Zone';
const String _shelfCode = 'M3-QA-SHELF';
const String _shelfLabel = 'M3 QA Shelf';
const String _batchCode = 'M3-QA-BATCH-1';
const double _batchQty = 5.0;

/// Quantity the stock flow normalizes this product to on every run. Delta-based
/// adjustment makes the suite repeatable: delta = target − current.
const double _targetQuantity = 10.0;

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
        costPrice: 3.5,
        sellingPrice: 9.99,
        reorderPoint: 5,
        reorderQuantity: 20,
        expiryTrackingEnabled: true,
      ),
    );
  } else if (product.status != 'active' || product.name != _baseName) {
    product = await api.updateProduct(
      store: store,
      id: product.id,
      update: ProductUpdate(
        status: 'active',
        name: _baseName,
        barcode: _productBarcode,
        costPrice: 3.5,
        sellingPrice: 9.99,
        reorderPoint: 5,
        reorderQuantity: 20,
        expiryTrackingEnabled: true,
      ),
    );
  }
  return product;
}

/// Reuse the deterministic zone by code, or create it once.
Future<Zone> _ensureZone(InventoryApi api, StoreInfo store) async {
  final zones = await api.listZones(store: store);
  final existing = zones.where((z) => z.code == _zoneCode).firstOrNull;
  if (existing != null) return existing;
  return api.createZone(store: store, name: _zoneName, code: _zoneCode);
}

/// Reuse the deterministic shelf by code, or create it once.
Future<Shelf> _ensureShelf(InventoryApi api, StoreInfo store, Zone zone) async {
  final shelves = await api.listShelves(store: store, zoneId: zone.id);
  final existing = shelves.where((s) => s.code == _shelfCode).firstOrNull;
  if (existing != null) return existing;
  return api.createShelf(store: store, zoneId: zone.id, label: _shelfLabel, code: _shelfCode);
}

/// Map the product to the shelf unless already mapped (unique constraint).
Future<void> _ensureMapping(InventoryApi api, StoreInfo store, Shelf shelf, String productId) async {
  final mapped = await api.listShelfProducts(store: store, shelfId: shelf.id);
  if (mapped.any((m) => m.productId == productId)) return;
  await api.mapProductToShelf(store: store, shelfId: shelf.id, productId: productId, isPrimary: true);
}

void main() {
  setUpAll(() async {
    if (_live) await _waitForBackend();
  });

  test(
    'stock live flow: list → ensure product → opening → delta normalize → detail → movements',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final api = InventoryApi(controller.apiClient);
      final catalog = CatalogApi(controller.apiClient);

      final product = await _ensureProduct(catalog, store);
      expect(product.sku, _productSku);

      // Set opening stock once; later runs keep the existing opening.
      var detail = await api.getStockDetail(store: store, productId: product.id);
      if (!detail.hasOpening) {
        detail = await api.setOpeningStock(store: store, productId: product.id, quantity: 100);
        expect(detail.hasOpening, isTrue);
        expect(detail.quantity, 100);
        expect(detail.recentMovements.first.movementType, MovementType.opening);
      }

      // Normalize to the target via a delta adjustment (concurrency-safe).
      final current = detail.quantity;
      final delta = _targetQuantity - current;
      if (delta.abs() > 0.001) {
        final adjusted = await api.adjustStock(
          store: store,
          productId: product.id,
          delta: delta,
          reason: 'M3 live QA normalize to $_targetQuantity',
        );
        expect(adjusted.quantity, closeTo(_targetQuantity, 0.001));
        expect(adjusted.recentMovements.first.movementType, MovementType.adjustment);
        expect(adjusted.recentMovements.first.resultingQuantity, closeTo(_targetQuantity, 0.001));
      }

      // Stock list contains the product at the normalized quantity.
      final listed = await api.listStock(store: store, q: _productSku);
      final row = listed.items.where((i) => i.productId == product.id).firstOrNull;
      expect(row, isNotNull, reason: 'product must appear in stock list');
      expect(row!.quantity, closeTo(_targetQuantity, 0.001));
      expect(row.stockStatus, StockStatus.healthy, reason: '10 > reorder point 5');

      // Summary is populated.
      final summary = await api.getStockSummary(store: store);
      expect(summary.totalProducts, greaterThanOrEqualTo(1));
      expect(summary.totalValue, greaterThan(0));
      expect(summary.healthy, greaterThanOrEqualTo(1));

      // Movements carry the adjustment record.
      final movements = await api.listMovements(store: store, productId: product.id);
      expect(movements.items, isA<List<StockMovement>>());
      final adjustment = movements.items.where((m) => m.movementType == MovementType.adjustment).firstOrNull;
      expect(adjustment, isNotNull, reason: 'an ADJUSTMENT movement must exist');
      expect(adjustment!.resultingQuantity, closeTo(_targetQuantity, 0.001));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'layout live flow: ensure zone → ensure shelf → map product → verify both directions',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final api = InventoryApi(controller.apiClient);
      final catalog = CatalogApi(controller.apiClient);

      final product = await _ensureProduct(catalog, store);
      final zone = await _ensureZone(api, store);
      expect(zone.code, _zoneCode);
      expect(zone.name, _zoneName);

      final shelf = await _ensureShelf(api, store, zone);
      expect(shelf.code, _shelfCode);
      expect(shelf.zoneId, zone.id);

      await _ensureMapping(api, store, shelf, product.id);

      // Mapping list exposes the product's name / sku / barcode.
      final mapped = await api.listShelfProducts(store: store, shelfId: shelf.id);
      final link = mapped.where((m) => m.productId == product.id).firstOrNull;
      expect(link, isNotNull, reason: 'product must be mapped to the shelf');
      expect(link!.productName, _baseName);
      expect(link.sku, _productSku);
      expect(link.barcode, _productBarcode);

      // Stock detail lists the shelf from the other direction.
      final detail = await api.getStockDetail(store: store, productId: product.id);
      final shelfRef = detail.shelves.where((s) => s.shelfId == shelf.id).firstOrNull;
      expect(shelfRef, isNotNull, reason: 'stock detail must reference the shelf');
      expect(shelfRef!.zoneName, _zoneName);

      // Zone and shelf reads work standalone.
      final zoneDetail = await api.getZone(store: store, zoneId: zone.id);
      expect(zoneDetail.id, zone.id);
      final shelfDetail = await api.getShelf(store: store, shelfId: shelf.id);
      expect(shelfDetail.id, shelf.id);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'expiry live flow: create batch → detail → edit → delete (cleanup)',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final api = InventoryApi(controller.apiClient);
      final catalog = CatalogApi(controller.apiClient);

      final product = await _ensureProduct(catalog, store);

      // Reuse the deterministic batch if a previous run left one behind, or
      // create it once. Only the create path has a fixed quantity.
      var batches = await api.listExpiryBatches(store: store, productId: product.id);
      var batch = batches.where((b) => b.batchCode == _batchCode).firstOrNull;
      if (batch == null) {
        batch = await api.createExpiryBatch(
          store: store,
          productId: product.id,
          quantity: _batchQty,
          expiryDate: DateTime(2027, 12, 31),
          batchCode: _batchCode,
        );
        expect(batch.quantity, _batchQty);
      }
      expect(batch.batchCode, _batchCode);
      expect(batch.status, 'normal', reason: 'expiry in 2027 must not be near/expired');
      expect(batch.daysRemaining, greaterThan(0));

      final batchId = batch.id;

      final detail = await api.getExpiryBatch(store: store, batchId: batchId);
      expect(detail.id, batchId);

      final updated = await api.updateExpiryBatch(
        store: store,
        batchId: batchId,
        expiryDate: DateTime(2028, 1, 15),
      );
      expect(updated.expiryDate, DateTime(2028, 1, 15));

      // A batch arrives with stock, so it must be drained through a delta
      // adjustment before the row can be deleted.
      final stockBefore = await api.getStockDetail(store: store, productId: product.id);
      if (batch.quantity > 0) {
        final drained = await api.adjustStock(
          store: store,
          productId: product.id,
          delta: -batch.quantity,
          expiryBatchId: batchId,
          reason: 'M3 live QA drain expiry batch',
        );
        expect(drained.quantity, closeTo(stockBefore.quantity - batch.quantity, 0.001));
      }

      // Cleanup: only a zero-quantity batch is deletable; the list must not
      // contain it afterwards.
      await api.deleteExpiryBatch(store: store, batchId: batchId);
      final afterCleanup = await api.listExpiryBatches(store: store, productId: product.id);
      expect(afterCleanup.any((b) => b.id == batchId), isFalse, reason: 'batch must be gone after delete');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'rbac live: inventory.view allows reads; adjust/layout/expiry/movements are 403',
    skip: _skip,
    () async {
      final controller = await _login(_viewerEmail, _viewerPassword);
      final permissions = controller.current!.permissions;
      expect(permissions, contains('inventory.view'));
      expect(permissions, isNot(contains('inventory.adjust')));
      expect(permissions, isNot(contains('inventory.manage_layout')));
      expect(permissions, isNot(contains('inventory.manage_expiry')));
      expect(permissions, isNot(contains('inventory.view_movements')));

      final store = controller.selectedStore!;
      final api = InventoryApi(controller.apiClient);

      // Reads granted by inventory.view.
      final page = await api.listStock(store: store, pageSize: 5);
      expect(page.items, isA<List<StockItem>>());
      final zones = await api.listZones(store: store);
      expect(zones, isA<List<Zone>>());
      final expiry = await api.listExpiryBatches(store: store);
      expect(expiry, isA<List<ExpiryBatch>>());

      // The deterministic product always exists: the stock live flow above
      // creates it and normalizes its quantity. The product id comes from the
      // inventory list (an inventory.view read) — the viewer has no products.*
      // permission, so the catalog API is off-limits here.
      final stock = await api.listStock(store: store, q: _productSku, pageSize: 5);
      expect(stock.items, isNotEmpty, reason: 'deterministic product must exist (stock live flow runs first)');
      final productId = stock.items.first.productId;

      // ADJUST on a readable product → 403.
      await expectLater(
        api.adjustStock(store: store, productId: productId, delta: 1, reason: 'M3 RBAC denied'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.code, 'code', 'FORBIDDEN'),
        ),
      );

      // OPENING (also requires inventory.adjust) → 403.
      await expectLater(
        api.setOpeningStock(store: store, productId: productId, quantity: 1),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.code, 'code', 'FORBIDDEN'),
        ),
      );

      // Movements require inventory.view_movements → 403.
      await expectLater(
        api.listMovements(store: store, productId: productId),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.code, 'code', 'FORBIDDEN'),
        ),
      );

      // Layout mutations require inventory.manage_layout → 403.
      await expectLater(
        api.createZone(store: store, name: 'M3-QA-RBAC-DENIED', code: 'm3-rbac-denied'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.code, 'code', 'FORBIDDEN'),
        ),
      );

      // Expiry mutations require inventory.manage_expiry → 403.
      await expectLater(
        api.createExpiryBatch(store: store, productId: productId, quantity: 1, expiryDate: DateTime(2030, 1, 1)),
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
