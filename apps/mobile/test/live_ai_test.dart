// M4 AI Count live integration — Flutter API layer → FastAPI → PostgreSQL.
//
// Proves the actual scan lifecycle against the real backend (create scan,
// process mock image bytes, detections, reconciliations, review PATCH, confirm)
// plus the RBAC boundary for ai.* permissions.
//
// Not part of the default suite. Requires a live backend; run with:
//   flutter test --dart-define=LIVE_API=true \
//                --dart-define=API_BASE_URL=http://127.0.0.1:8000
//                test/live_ai_test.dart
//
// No MockClient is used anywhere in this file — every request is real.
//
// Test data is deterministic (fixed SKU / zone / shelf codes) and idempotent:
// each run reuses existing product / zone / shelf records. The scan session is
// deliberately created fresh per run (POST /ai/scans always 201-creates an
// audit record), so repeated runs accumulate confirmed sessions — expected QA
// behaviour, not a failure.
//
// RBAC: `scripts/provision_rbac_ai_viewer.py` must be run once so that
// ai-viewer@acme.com exists with ONLY `ai.view`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:visionstock_mobile/core/api/auth_api.dart';
import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/config.dart';
import 'package:visionstock_mobile/core/models/auth_models.dart';
import 'package:visionstock_mobile/core/session.dart';
import 'package:visionstock_mobile/core/session_store.dart';
import 'package:visionstock_mobile/features/ai/data/ai_api.dart';
import 'package:visionstock_mobile/features/ai/data/ai_models.dart';
import 'package:visionstock_mobile/features/ai/data/mock_scan_image.dart';
import 'package:visionstock_mobile/features/catalog/data/catalog_api.dart';
import 'package:visionstock_mobile/features/catalog/data/catalog_models.dart';
import 'package:visionstock_mobile/features/inventory/data/inventory_api.dart';
import 'package:visionstock_mobile/features/inventory/data/inventory_models.dart';

const bool _live = bool.fromEnvironment('LIVE_API', defaultValue: false);

const String _ownerEmail = String.fromEnvironment(
  'TEST_USER_EMAIL',
  defaultValue: 'owner@acme.com',
);
const String _ownerPassword = String.fromEnvironment(
  'TEST_USER_PASSWORD',
  defaultValue: 'Test1234!',
);
const String _aiViewerEmail = String.fromEnvironment(
  'TEST_AI_VIEWER_EMAIL',
  defaultValue: 'ai-viewer@acme.com',
);
const String _aiViewerPassword = String.fromEnvironment(
  'TEST_AI_VIEWER_PASSWORD',
  defaultValue: 'Test1234!',
);

/// Base URL: env override → compile-time dart-define → AppConfig default.
String get _baseUrl =>
    Platform.environment['API_BASE_URL'] ?? AppConfig.apiBaseUrl;

final bool _skip = !_live;

// Deterministic identities (idempotent across runs).
const String _productSku = 'M4-QA-PROD-001';
const String _productBarcode = '2400000000123';
const String _baseName = 'M4 QA Product';
const String _zoneCode = 'M4-QA-ZONE';
const String _zoneName = 'M4 QA Zone';
const String _shelfCode = 'M4-QA-SHELF';
const String _shelfLabel = 'M4 QA Shelf';

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
  final controller = SessionController(
    storage: MemorySessionStorage(),
    api: AuthApi(apiClient),
  );
  await controller.login(email: email, password: password);
  return controller;
}

/// Create, or reset an existing record to, the deterministic baseline product.
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
        expiryTrackingEnabled: false,
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
        expiryTrackingEnabled: false,
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
  return api.createShelf(
    store: store,
    zoneId: zone.id,
    label: _shelfLabel,
    code: _shelfCode,
  );
}

/// Mock image bytes matching the deterministic product by barcode.
List<int> _mockImageBytes() => encodeMockImage(const [
  MockScanItem(
    method: 'barcode',
    detectedBarcode: _productBarcode,
    detectedSku: _productSku,
    confidence: 0.98,
    quantity: 1,
  ),
]);

/// Low-confidence visual mock → the session lands in `needs_review` so the
/// reviewer (PATCH) path is exercised.
List<int> _reviewMockImageBytes({required double quantity}) => encodeMockImage([
  MockScanItem(
    method: 'visual',
    detectedBarcode: _productBarcode,
    detectedSku: _productSku,
    confidence: 0.45,
    quantity: quantity,
  ),
]);

/// Normalize the deterministic product's on-hand quantity to [target] so the
/// review-flow assertions are deterministic regardless of prior runs.
Future<void> _normalizeStock(
  InventoryApi inventory,
  StoreInfo store,
  String productId,
  double target,
) async {
  final detail = await inventory.getStockDetail(
    store: store,
    productId: productId,
  );
  if (!detail.hasOpening) {
    await inventory.setOpeningStock(
      store: store,
      productId: productId,
      quantity: 100,
    );
  }
  final delta = target - detail.quantity;
  if (delta.abs() > 0.001) {
    await inventory.adjustStock(
      store: store,
      productId: productId,
      delta: delta,
      reason: 'M4 live PATCH QA normalize',
    );
  }
}

/// Create + process a low-confidence scan; returns the `needs_review` session
/// together with its deterministic product.
Future<({ScanSession session, Product product})> _createReviewScan({
  required AiApi ai,
  required InventoryApi inventory,
  required CatalogApi catalog,
  required StoreInfo store,
  double detectedQuantity = 2,
}) async {
  final product = await _ensureProduct(catalog, store);
  final zone = await _ensureZone(inventory, store);
  final shelf = await _ensureShelf(inventory, store, zone);
  final created = await ai.createScan(
    store: store,
    operation: AiScanOperation.count,
    shelfId: shelf.id,
    note: 'M4 live PATCH QA',
  );
  final processed = await ai.processScan(
    store: store,
    sessionId: created.id,
    imageBytes: _reviewMockImageBytes(quantity: detectedQuantity),
  );
  expect(
    processed.status,
    'needs_review',
    reason: 'low-confidence mock must land the session in needs_review',
  );
  return (session: processed, product: product);
}

Future<ScanReconciliation> _findRecon(
  AiApi ai,
  StoreInfo store,
  String sessionId,
  String productId,
) async {
  final rows = await ai.getReconciliations(store: store, sessionId: sessionId);
  final recon = rows.where((r) => r.productId == productId).firstOrNull;
  expect(
    recon,
    isNotNull,
    reason: 'expected a reconciliation row for the deterministic product',
  );
  return recon!;
}

Future<StockMovement?> _movement(
  InventoryApi inventory,
  StoreInfo store,
  String productId,
  String sessionId,
  String movementType,
) async {
  final movements = await inventory.listMovements(
    store: store,
    productId: productId,
    movementType: movementType,
  );
  return movements.items.where((m) => m.referenceId == sessionId).firstOrNull;
}

void main() {
  setUpAll(() async {
    if (_live) await _waitForBackend();
  });

  test(
    'scan live flow: create → process mock image → detections → reconciliations → confirm',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final ai = AiApi(controller.apiClient);
      final inventory = InventoryApi(controller.apiClient);
      final catalog = CatalogApi(controller.apiClient);

      final product = await _ensureProduct(catalog, store);
      final zone = await _ensureZone(inventory, store);
      final shelf = await _ensureShelf(inventory, store, zone);
      expect(product.barcode, _productBarcode);

      // 1. Create a scan scoped to the deterministic shelf.
      final created = await ai.createScan(
        store: store,
        operation: AiScanOperation.count,
        shelfId: shelf.id,
        note: 'M4 live QA',
      );
      expect(created.status, 'processing');
      expect(created.operation, AiScanOperation.count);
      expect(created.shelfId, shelf.id);

      // 2. Process mock image bytes → completed with a matched detection.
      final processed = await ai.processScan(
        store: store,
        sessionId: created.id,
        imageBytes: _mockImageBytes(),
      );
      expect(processed.status, 'completed');
      expect(processed.imageCount, greaterThanOrEqualTo(1));

      // 3. Detections carry the deterministic product, matched as accepted.
      final detections = await ai.getDetections(
        store: store,
        sessionId: created.id,
      );
      final matched = detections
          .where((d) => d.productId == product.id)
          .firstOrNull;
      expect(
        matched,
        isNotNull,
        reason: 'mock image barcode must match the deterministic product',
      );
      expect(matched!.status, 'accepted');
      expect(matched.detectedBarcode, _productBarcode);
      expect(matched.quantityDetected, greaterThan(0));

      // 4. Reconciliations expose the product with a computed variance.
      final reconciliations = await ai.getReconciliations(
        store: store,
        sessionId: created.id,
      );
      final recon = reconciliations
          .where((r) => r.productId == product.id)
          .firstOrNull;
      expect(
        recon,
        isNotNull,
        reason: 'a matched detection must produce a reconciliation row',
      );
      expect(recon!.detectedQuantity, greaterThan(0));

      // 5. Confirm applies counts; the session becomes confirmed.
      final confirmed = await ai.confirmScan(
        store: store,
        sessionId: created.id,
      );
      expect(confirmed.status, 'confirmed');

      final readBack = await ai.getScan(store: store, sessionId: created.id);
      expect(readBack.status, 'confirmed');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'scan error surface: unknown scan id → typed 404 NOT_FOUND on every read',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final ai = AiApi(controller.apiClient);

      // A well-formed but nonexistent scan id → 404 (a malformed id would be
      // a 422 path-validation error, which is a different contract).
      await expectLater(
        ai.getScan(
          store: store,
          sessionId: '00000000-0000-0000-0000-000000000000',
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.code, 'code', 'NOT_FOUND'),
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'rbac live: ai.view allows reads; create/process/confirm/PATCH are 403',
    skip: _skip,
    () async {
      // Owner creates a scan the viewer will read.
      final owner = await _login(_ownerEmail, _ownerPassword);
      final ownerStore = owner.selectedStore!;
      final ownerAi = AiApi(owner.apiClient);
      final created = await ownerAi.createScan(
        store: ownerStore,
        operation: AiScanOperation.count,
        note: 'M4 RBAC read target',
      );

      final controller = await _login(_aiViewerEmail, _aiViewerPassword);
      final permissions = controller.current!.permissions;
      expect(permissions, contains('ai.view'));
      expect(permissions, isNot(contains('ai.scan')));
      expect(permissions, isNot(contains('ai.reconcile')));
      expect(permissions, isNot(contains('ai.confirm')));

      final store = controller.selectedStore!;
      final ai = AiApi(controller.apiClient);

      // Reads granted by ai.view: scan + detections + reconciliations.
      final session = await ai.getScan(store: store, sessionId: created.id);
      expect(session.id, created.id);
      final detections = await ai.getDetections(
        store: store,
        sessionId: created.id,
      );
      expect(detections, isA<List<ScanDetection>>());
      final reconciliations = await ai.getReconciliations(
        store: store,
        sessionId: created.id,
      );
      expect(reconciliations, isA<List<ScanReconciliation>>());

      // PATCH (review decision) requires ai.reconcile → 403.
      await expectLater(
        ai.updateReconciliation(
          store: store,
          sessionId: created.id,
          reconciliationId: '00000000-0000-0000-0000-000000000000',
          resolution: 'apply',
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.code, 'code', 'FORBIDDEN'),
        ),
      );

      // CREATE requires ai.scan → 403.
      await expectLater(
        ai.createScan(store: store, operation: AiScanOperation.count),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.code, 'code', 'FORBIDDEN'),
        ),
      );

      // PROCESS requires ai.scan → 403.
      await expectLater(
        ai.processScan(
          store: store,
          sessionId: created.id,
          imageBytes: _mockImageBytes(),
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.code, 'code', 'FORBIDDEN'),
        ),
      );

      // CONFIRM requires ai.confirm → 403.
      await expectLater(
        ai.confirmScan(store: store, sessionId: created.id),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.code, 'code', 'FORBIDDEN'),
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'patch live: apply → confirm → COUNT movement uses detected quantity',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final ai = AiApi(controller.apiClient);
      final inventory = InventoryApi(controller.apiClient);
      final catalog = CatalogApi(controller.apiClient);

      const system = 3.0;
      const detected = 2.0;
      final product = await _ensureProduct(catalog, store);
      await _normalizeStock(inventory, store, product.id, system);

      final created = await _createReviewScan(
        ai: ai,
        inventory: inventory,
        catalog: catalog,
        store: store,
        detectedQuantity: detected,
      );
      final sessionId = created.session.id;
      final recon = await _findRecon(ai, store, sessionId, product.id);
      expect(recon.detectedQuantity, closeTo(detected, 0.001));
      expect(recon.systemQuantity, closeTo(system, 0.001));
      expect(recon.variance, closeTo(detected - system, 0.001));

      final applied = await ai.updateReconciliation(
        store: store,
        sessionId: sessionId,
        reconciliationId: recon.id,
        resolution: 'apply',
      );
      expect(applied.resolution, 'apply');
      expect(applied.status, 'needs_review');

      final confirmed = await ai.confirmScan(
        store: store,
        sessionId: sessionId,
      );
      expect(confirmed.status, 'confirmed');

      final count = await _movement(
        inventory,
        store,
        product.id,
        sessionId,
        MovementType.count,
      );
      expect(
        count,
        isNotNull,
        reason: 'applied reconciliation must write a COUNT movement',
      );
      expect(count!.quantityDelta, closeTo(detected - system, 0.001));
      expect(count.resultingQuantity, closeTo(detected, 0.001));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'patch live: ignore → confirm → no COUNT movement, stock unchanged',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final ai = AiApi(controller.apiClient);
      final inventory = InventoryApi(controller.apiClient);
      final catalog = CatalogApi(controller.apiClient);

      const system = 3.0;
      const detected = 2.0;
      final product = await _ensureProduct(catalog, store);
      await _normalizeStock(inventory, store, product.id, system);

      final created = await _createReviewScan(
        ai: ai,
        inventory: inventory,
        catalog: catalog,
        store: store,
        detectedQuantity: detected,
      );
      final sessionId = created.session.id;
      final recon = await _findRecon(ai, store, sessionId, product.id);

      final ignored = await ai.updateReconciliation(
        store: store,
        sessionId: sessionId,
        reconciliationId: recon.id,
        resolution: 'ignore',
      );
      expect(ignored.resolution, 'ignore');
      expect(ignored.status, 'needs_review');

      final confirmed = await ai.confirmScan(
        store: store,
        sessionId: sessionId,
      );
      expect(confirmed.status, 'confirmed');

      final count = await _movement(
        inventory,
        store,
        product.id,
        sessionId,
        MovementType.count,
      );
      expect(
        count,
        isNull,
        reason: 'ignored reconciliation must not write a COUNT movement',
      );
      final detail = await inventory.getStockDetail(
        store: store,
        productId: product.id,
      );
      expect(
        detail.quantity,
        closeTo(system, 0.001),
        reason: 'ignore must not mutate stock',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'patch live: override → confirm → COUNT movement uses overridden quantity',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final ai = AiApi(controller.apiClient);
      final inventory = InventoryApi(controller.apiClient);
      final catalog = CatalogApi(controller.apiClient);

      const system = 3.0;
      const overridden = 7.0;
      final product = await _ensureProduct(catalog, store);
      await _normalizeStock(inventory, store, product.id, system);

      final created = await _createReviewScan(
        ai: ai,
        inventory: inventory,
        catalog: catalog,
        store: store,
        detectedQuantity: 2,
      );
      final sessionId = created.session.id;
      final recon = await _findRecon(ai, store, sessionId, product.id);

      final updated = await ai.updateReconciliation(
        store: store,
        sessionId: sessionId,
        reconciliationId: recon.id,
        resolution: 'apply',
        detectedQuantity: overridden,
      );
      expect(updated.detectedQuantity, closeTo(overridden, 0.001));
      expect(updated.variance, closeTo(overridden - system, 0.001));

      final confirmed = await ai.confirmScan(
        store: store,
        sessionId: sessionId,
      );
      expect(confirmed.status, 'confirmed');

      final count = await _movement(
        inventory,
        store,
        product.id,
        sessionId,
        MovementType.count,
      );
      expect(
        count,
        isNotNull,
        reason: 'override must still produce a COUNT movement',
      );
      expect(count!.quantityDelta, closeTo(overridden - system, 0.001));
      expect(count.resultingQuantity, closeTo(overridden, 0.001));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'patch live: validation → 422 on negative / unknown resolution / ignore+quantity',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final ai = AiApi(controller.apiClient);
      final inventory = InventoryApi(controller.apiClient);
      final catalog = CatalogApi(controller.apiClient);

      final product = await _ensureProduct(catalog, store);
      await _normalizeStock(inventory, store, product.id, 3.0);

      final created = await _createReviewScan(
        ai: ai,
        inventory: inventory,
        catalog: catalog,
        store: store,
      );
      final sessionId = created.session.id;
      final recon = await _findRecon(ai, store, sessionId, product.id);

      Future<void> expect422(Future<ScanReconciliation> Function() call) async {
        await expectLater(
          call(),
          throwsA(
            isA<ApiException>()
                .having((e) => e.statusCode, 'statusCode', 422)
                .having((e) => e.code, 'code', 'VALIDATION_ERROR'),
          ),
        );
      }

      // detected_quantity < 0 → schema constraint.
      await expect422(
        () => ai.updateReconciliation(
          store: store,
          sessionId: sessionId,
          reconciliationId: recon.id,
          resolution: 'apply',
          detectedQuantity: -1,
        ),
      );
      // Unknown resolution → Literal rejection.
      await expect422(
        () => ai.updateReconciliation(
          store: store,
          sessionId: sessionId,
          reconciliationId: recon.id,
          resolution: 'bogus',
        ),
      );
      // ignore cannot carry a detected_quantity → model validator.
      await expect422(
        () => ai.updateReconciliation(
          store: store,
          sessionId: sessionId,
          reconciliationId: recon.id,
          resolution: 'ignore',
          detectedQuantity: 5,
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'patch live: isolation → cross-session / unknown id / alien store all 404',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final ai = AiApi(controller.apiClient);
      final inventory = InventoryApi(controller.apiClient);
      final catalog = CatalogApi(controller.apiClient);

      final product = await _ensureProduct(catalog, store);
      await _normalizeStock(inventory, store, product.id, 3.0);

      final a = await _createReviewScan(
        ai: ai,
        inventory: inventory,
        catalog: catalog,
        store: store,
      );
      final b = await _createReviewScan(
        ai: ai,
        inventory: inventory,
        catalog: catalog,
        store: store,
      );
      final reconA = await _findRecon(ai, store, a.session.id, product.id);

      Future<void> expect404(Future<ScanReconciliation> Function() call) async {
        await expectLater(
          call(),
          throwsA(
            isA<ApiException>()
                .having((e) => e.statusCode, 'statusCode', 404)
                .having((e) => e.code, 'code', 'NOT_FOUND'),
          ),
        );
      }

      // Reconciliation row from session A under session B's path → 404.
      await expect404(
        () => ai.updateReconciliation(
          store: store,
          sessionId: b.session.id,
          reconciliationId: reconA.id,
          resolution: 'apply',
        ),
      );
      // Unknown reconciliation id under a valid session → 404.
      await expect404(
        () => ai.updateReconciliation(
          store: store,
          sessionId: a.session.id,
          reconciliationId: '00000000-0000-0000-0000-000000000000',
          resolution: 'apply',
        ),
      );
      // Unknown scan id → 404.
      await expect404(
        () => ai.updateReconciliation(
          store: store,
          sessionId: '00000000-0000-0000-0000-000000000000',
          reconciliationId: reconA.id,
          resolution: 'apply',
        ),
      );
      // A store the token cannot access → 404 (never 403/200).
      final alien = StoreInfo(
        id: '11111111-1111-1111-1111-111111111111',
        name: 'alien',
        timezone: 'UTC',
        currency: 'USD',
      );
      await expect404(
        () => ai.updateReconciliation(
          store: alien,
          sessionId: a.session.id,
          reconciliationId: reconA.id,
          resolution: 'apply',
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'patch live: confirm is single-shot → second confirm → 409',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final ai = AiApi(controller.apiClient);
      final inventory = InventoryApi(controller.apiClient);
      final catalog = CatalogApi(controller.apiClient);

      final product = await _ensureProduct(catalog, store);
      await _normalizeStock(inventory, store, product.id, 3.0);

      final created = await _createReviewScan(
        ai: ai,
        inventory: inventory,
        catalog: catalog,
        store: store,
      );
      final sessionId = created.session.id;
      final recon = await _findRecon(ai, store, sessionId, product.id);
      await ai.updateReconciliation(
        store: store,
        sessionId: sessionId,
        reconciliationId: recon.id,
        resolution: 'apply',
      );

      final confirmed = await ai.confirmScan(
        store: store,
        sessionId: sessionId,
      );
      expect(confirmed.status, 'confirmed');

      await expectLater(
        ai.confirmScan(store: store, sessionId: sessionId),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.code, 'code', 'CONFLICT'),
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'operations live: receive → confirm adds +detected as PURCHASE and raises stock',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final ai = AiApi(controller.apiClient);
      final inventory = InventoryApi(controller.apiClient);
      final catalog = CatalogApi(controller.apiClient);

      const system = 5.0;
      final product = await _ensureProduct(catalog, store);
      await _normalizeStock(inventory, store, product.id, system);

      final created = await ai.createScan(
        store: store,
        operation: AiScanOperation.receive,
        note: 'M4 live RECEIVE QA',
      );
      expect(created.operation, AiScanOperation.receive);
      expect(created.shelfId, isNull);

      final processed = await ai.processScan(
        store: store,
        sessionId: created.id,
        imageBytes: _mockImageBytes(), // detected quantity 1
      );
      expect(processed.status, 'completed');

      final confirmed = await ai.confirmScan(
        store: store,
        sessionId: created.id,
      );
      expect(confirmed.status, 'confirmed');

      final purchase = await _movement(
        inventory,
        store,
        product.id,
        created.id,
        MovementType.purchase,
      );
      expect(
        purchase,
        isNotNull,
        reason: 'receive confirm must write a PURCHASE movement',
      );
      expect(purchase!.quantityDelta, closeTo(1, 0.001));
      expect(purchase.resultingQuantity, closeTo(system + 1, 0.001));
      final detail = await inventory.getStockDetail(
        store: store,
        productId: product.id,
      );
      expect(detail.quantity, closeTo(system + 1, 0.001));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'operations live: sale → confirm subtracts detected as SALE and lowers stock',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final ai = AiApi(controller.apiClient);
      final inventory = InventoryApi(controller.apiClient);
      final catalog = CatalogApi(controller.apiClient);

      const system = 5.0;
      final product = await _ensureProduct(catalog, store);
      await _normalizeStock(inventory, store, product.id, system);

      final created = await ai.createScan(
        store: store,
        operation: AiScanOperation.sale,
        note: 'M4 live SALE QA',
      );
      expect(created.operation, AiScanOperation.sale);
      expect(created.shelfId, isNull);

      final processed = await ai.processScan(
        store: store,
        sessionId: created.id,
        imageBytes: _mockImageBytes(), // detected quantity 1
      );
      expect(processed.status, 'completed');

      final confirmed = await ai.confirmScan(
        store: store,
        sessionId: created.id,
      );
      expect(confirmed.status, 'confirmed');

      final sale = await _movement(
        inventory,
        store,
        product.id,
        created.id,
        MovementType.sale,
      );
      expect(
        sale,
        isNotNull,
        reason: 'sale confirm must write a SALE movement',
      );
      expect(sale!.quantityDelta, closeTo(-1, 0.001));
      expect(sale.resultingQuantity, closeTo(system - 1, 0.001));
      final detail = await inventory.getStockDetail(
        store: store,
        productId: product.id,
      );
      expect(detail.quantity, closeTo(system - 1, 0.001));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'operations live: sale with detected > available → confirm 422, no movement',
    skip: _skip,
    () async {
      final controller = await _login(_ownerEmail, _ownerPassword);
      final store = controller.selectedStore!;
      final ai = AiApi(controller.apiClient);
      final inventory = InventoryApi(controller.apiClient);
      final catalog = CatalogApi(controller.apiClient);

      final product = await _ensureProduct(catalog, store);
      await _normalizeStock(inventory, store, product.id, 0.5);

      final created = await ai.createScan(
        store: store,
        operation: AiScanOperation.sale,
        note: 'M4 live SALE insufficient QA',
      );
      final processed = await ai.processScan(
        store: store,
        sessionId: created.id,
        imageBytes: _mockImageBytes(), // detected quantity 1 > 0.5 available
      );
      expect(processed.status, 'completed');

      await expectLater(
        ai.confirmScan(store: store, sessionId: created.id),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 422)
              .having((e) => e.code, 'code', 'VALIDATION_ERROR'),
        ),
      );

      final sale = await _movement(
        inventory,
        store,
        product.id,
        created.id,
        MovementType.sale,
      );
      expect(sale, isNull, reason: 'rejected sale must not write a movement');
      final detail = await inventory.getStockDetail(
        store: store,
        productId: product.id,
      );
      expect(detail.quantity, closeTo(0.5, 0.001));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
