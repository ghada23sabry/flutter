import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/cache.dart';
import 'package:visionstock_mobile/core/session_store.dart';
import 'package:visionstock_mobile/core/widgets/app_card.dart';
import 'package:visionstock_mobile/main.dart';

// Full permissions used by the "manage" tests; zone/shelf/expiry mutations and
// mapping are additionally gated by their own permission codes.
const _fullPermissions = [
  'products.view',
  'inventory.view',
  'inventory.adjust',
  'inventory.manage_layout',
  'inventory.view_movements',
  'inventory.manage_expiry',
];

// View-only inventory: no manage_layout / view_movements / manage_expiry.
const _viewOnlyPermissions = ['products.view', 'inventory.view'];

const _store = {
  'id': 's1',
  'name': 'Downtown',
  'timezone': 'UTC',
  'currency': 'USD',
};

Map<String, dynamic> _loginPayload(List<String> permissions) => {
  'access_token': 'a-token',
  'refresh_token': 'r-token',
  'expires_in': 900,
  'user': {
    'id': 'u1',
    'email': 'owner@test.dev',
    'name': 'Owner',
    'status': 'active',
  },
  'permissions': permissions,
  'stores': [_store],
};

Map<String, dynamic> _mePayload(List<String> permissions) => {
  'user': {
    'id': 'u1',
    'email': 'owner@test.dev',
    'name': 'Owner',
    'status': 'active',
  },
  'permissions': permissions,
  'stores': [_store],
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

http.Response _error(String code, String message, [int status = 500]) => _json({
  'detail': {'code': code, 'message': message},
}, status);

http.Response _notFound() => _error('NOT_FOUND', 'Not found', 404);

Map<String, dynamic> _page(List<Map<String, dynamic>> items) => {
  'items': items,
  'total': items.length,
  'page': 1,
  'page_size': 50,
  'pages': items.isEmpty ? 0 : 1,
};

String _skuOf(String productId) =>
    productId == 'p1' ? 'SKU-1' : (productId == 'p2' ? 'SKU-2' : 'SKU-3');

Map<String, dynamic> _zoneJson({
  required String id,
  required String name,
  String? code,
  String status = 'active',
}) => {
  'id': id,
  'store_id': 's1',
  'name': name,
  'code': code,
  'status': status,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
};

Map<String, dynamic> _shelfJson({
  required String id,
  required String zoneId,
  required String label,
  String? code,
  String? zoneName,
  int position = 0,
  String status = 'active',
}) => {
  'id': id,
  'store_id': 's1',
  'zone_id': zoneId,
  'zone_name': zoneName,
  'label': label,
  'code': code,
  'position': position,
  'status': status,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
};

Map<String, dynamic> _mappingJson({
  required String id,
  String shelfId = 'sh1',
  required String productId,
  required String productName,
  String? sku,
  int position = 0,
  bool isPrimary = false,
}) => {
  'id': id,
  'shelf_id': shelfId,
  'product_id': productId,
  'position': position,
  'is_primary': isPrimary,
  'product_name': productName,
  'sku': sku,
  'barcode': null,
};

Map<String, dynamic> _productJson({required String id, required String name}) =>
    {
      'id': id,
      'store_id': 's1',
      'category_id': null,
      'category_name': null,
      'sku': _skuOf(id),
      'barcode': null,
      'name': name,
      'description': null,
      'unit': 'pcs',
      'cost_price': 0.8,
      'selling_price': 1.5,
      'reorder_point': 10.0,
      'reorder_quantity': 50.0,
      'expiry_tracking_enabled': false,
      'image_url': null,
      'status': 'active',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _expiryJson({
  required String id,
  required String productId,
  required String productName,
  String? batchCode,
  required String quantity,
  String expiryDate = '2027-12-31',
  required int days,
  required String status,
}) => {
  'id': id,
  'product_id': productId,
  'product_name': productName,
  'sku': _skuOf(productId),
  'barcode': null,
  'batch_code': batchCode,
  'quantity': quantity,
  'expiry_date': expiryDate,
  'received_at': '2026-01-01T00:00:00Z',
  'status': status,
  'days_remaining': days,
  'value': '0.00',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
};

Map<String, dynamic> _movementJson({
  required String id,
  required String productId,
  required String productName,
  required String type,
  required String delta,
  required String resulting,
}) => {
  'id': id,
  'product_id': productId,
  'product_name': productName,
  'sku': _skuOf(productId),
  'quantity_delta': delta,
  'resulting_quantity': resulting,
  'movement_type': type,
  'reference_type': null,
  'reference_id': null,
  'notes': 'Opening stock',
  'created_by': 'u1',
  'created_by_name': 'Owner',
  'created_at': '2026-01-02T00:00:00Z',
};

Map<String, dynamic> _stockItemJson({
  required String id,
  required String name,
  required String status,
}) => {
  'product_id': id,
  'product_name': name,
  'sku': _skuOf(id),
  'barcode': null,
  'unit': 'pcs',
  'category_name': null,
  'cost_price': '0.80',
  'reorder_point': '10.000',
  'reorder_quantity': '50.000',
  'expiry_tracking_enabled': false,
  'quantity': '10.000',
  'reserved_quantity': '0.000',
  'available_quantity': '10.000',
  'stock_status': status,
  'value': '1.50',
  'nearest_expiry_date': null,
  'nearest_expiry_status': null,
  'updated_at': '2026-01-01T00:00:00Z',
};

const _summaryJson = {
  'total_products': 2,
  'total_value': '12.50',
  'healthy': 1,
  'low_stock': 1,
  'out_of_stock': 0,
  'near_expiry': 0,
  'expired': 0,
};

/// Stateful mock backend for the inventory domain, recording every mutation.
///
/// Flags:
/// - [failZones] / [failMovements]: first list load returns 500 (retry test).
/// - [failProducts]: `GET /products` throws a raw exception (picker test).
/// - [seedShelf]: seed one shelf `FZ-A1` inside zone `Frozen`.
/// - [seedMapping]: seed one Cola mapping on the seeded shelf.
class _Backend {
  _Backend({
    List<String>? permissions,
    this.failZones = false,
    this.failMovements = false,
    this.failProducts = false,
    this.seedShelf = false,
    this.seedMapping = false,
  }) : permissions = permissions ?? _fullPermissions {
    zones.addAll([
      _zoneJson(id: 'z1', name: 'Frozen', code: 'FZ'),
      _zoneJson(id: 'z2', name: 'Dairy', code: 'DA', status: 'inactive'),
    ]);
    if (seedShelf) {
      shelves.add(
        _shelfJson(
          id: 'sh1',
          zoneId: 'z1',
          zoneName: 'Frozen',
          label: 'FZ-A1',
          code: 'S-01',
        ),
      );
    }
    if (seedMapping) {
      mappings.add(
        _mappingJson(
          id: 'm1',
          shelfId: 'sh1',
          productId: 'p1',
          productName: 'Cola 330ml',
          sku: 'SKU-1',
        ),
      );
    }
    expiry.addAll([
      _expiryJson(
        id: 'eb1',
        productId: 'p1',
        productName: 'Cola 330ml',
        batchCode: 'LOT-A',
        quantity: '12.000',
        expiryDate: '2027-12-31',
        days: 500,
        status: 'normal',
      ),
      _expiryJson(
        id: 'eb2',
        productId: 'p2',
        productName: 'Milk 1L',
        batchCode: 'LOT-B',
        quantity: '0.000',
        expiryDate: '2026-01-01',
        days: -3,
        status: 'expired',
      ),
      _expiryJson(
        id: 'eb3',
        productId: 'p3',
        productName: 'Yogurt 500g',
        batchCode: 'LOT-C',
        quantity: '8.000',
        expiryDate: '2026-01-05',
        days: -5,
        status: 'expired',
      ),
    ]);
    movements.addAll([
      _movementJson(
        id: 'mv1',
        productId: 'p1',
        productName: 'Cola 330ml',
        type: 'OPENING',
        delta: '10.000',
        resulting: '10.000',
      ),
      _movementJson(
        id: 'mv2',
        productId: 'p2',
        productName: 'Water 500ml',
        type: 'ADJUSTMENT',
        delta: '-2.000',
        resulting: '8.000',
      ),
    ]);
    products.addAll([
      _productJson(id: 'p1', name: 'Cola 330ml'),
      _productJson(id: 'p2', name: 'Water 500ml'),
    ]);
    stock.addAll([
      _stockItemJson(id: 'p1', name: 'Cola 330ml', status: 'healthy'),
      _stockItemJson(id: 'p2', name: 'Water 500ml', status: 'low_stock'),
    ]);
  }

  final List<String> permissions;
  final bool failZones;
  final bool failMovements;
  final bool failProducts;
  final bool seedShelf;
  final bool seedMapping;

  var zoneFailuresRemaining = 0;
  var movementFailuresRemaining = 0;

  final zones = <Map<String, dynamic>>[];
  final shelves = <Map<String, dynamic>>[];
  final mappings = <Map<String, dynamic>>[];
  final expiry = <Map<String, dynamic>>[];
  final movements = <Map<String, dynamic>>[];
  final products = <Map<String, dynamic>>[];
  final stock = <Map<String, dynamic>>[];

  final zoneCreateBodies = <Map<String, dynamic>>[];
  final zonePatchBodies = <Map<String, dynamic>>[];
  final shelfCreateBodies = <Map<String, dynamic>>[];
  final shelfPatchBodies = <Map<String, dynamic>>[];
  final mapBodies = <Map<String, dynamic>>[];
  final expiryCreateBodies = <Map<String, dynamic>>[];
  final expiryPatchBodies = <Map<String, dynamic>>[];
  final expiryWriteOffBodies = <Map<String, dynamic>>[];
  final stockPatchBodies = <Map<String, dynamic>>[];
  final deleteCalls = <String>[];
  String? lastMovementsType;

  late final ApiClient client = ApiClient(
    baseUrl: 'http://test',
    client: MockClient(_handle),
  );

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    final method = request.method;
    final query = request.url.queryParameters;

    if (path == '/auth/login') return _json(_loginPayload(permissions));
    if (path == '/auth/me') return _json(_mePayload(permissions));

    if (path == '/products') {
      if (failProducts) throw Exception('internal detail: malformed payload');
      return _json(_page(products));
    }

    if (path == '/inventory/stock/summary') return _json(_summaryJson);

    if (path == '/inventory/stock') {
      final status = query['stock_status'];
      final items = status == null
          ? List<Map<String, dynamic>>.from(stock)
          : [
              for (final s in stock)
                if (s['stock_status'] == status) s,
            ];
      return _json(_page(items));
    }

    final stockDetailMatch = RegExp(
      r'^/inventory/stock/([^/]+)$',
    ).firstMatch(path);
    if (stockDetailMatch != null && method == 'GET') {
      final id = stockDetailMatch.group(1)!;
      final item = stock.firstWhere(
        (s) => s['product_id'] == id,
        orElse: () =>
            _stockItemJson(id: id, name: 'Unknown', status: 'healthy'),
      );
      return _json({
        ...item,
        'category_id': null,
        'category_name': null,
        'selling_price': '1.50',
        'has_opening': true,
        'shelves': <Object>[],
        'expiry_batches': [
          for (final e in expiry)
            if (e['product_id'] == id) e,
        ],
        'recent_movements': <Object>[],
      });
    }
    if (stockDetailMatch != null && method == 'PATCH') {
      stockPatchBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      final id = stockDetailMatch.group(1)!;
      final item = stock.firstWhere(
        (s) => s['product_id'] == id,
        orElse: () =>
            _stockItemJson(id: id, name: 'Unknown', status: 'healthy'),
      );
      return _json({...item, 'has_opening': true});
    }

    if (path == '/inventory/movements') {
      if (failMovements && movementFailuresRemaining < 1) {
        movementFailuresRemaining += 1;
        return _error('HTTP_500', 'Request failed (500)');
      }
      lastMovementsType = query['movement_type'];
      final type = query['movement_type'];
      final items = type == null
          ? List<Map<String, dynamic>>.from(movements)
          : [
              for (final m in movements)
                if (m['movement_type'] == type) m,
            ];
      return _json(_page(items));
    }

    if (path == '/inventory/zones' && method == 'GET') {
      if (failZones && zoneFailuresRemaining < 1) {
        zoneFailuresRemaining += 1;
        return _error('HTTP_500', 'Request failed (500)');
      }
      return _json(zones);
    }
    if (path == '/inventory/zones' && method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      zoneCreateBodies.add(body);
      final zone = _zoneJson(
        id: 'z${zones.length + 1}',
        name: body['name'] as String,
        code: body['code'] as String?,
      );
      zones.add(zone);
      return _json(zone, 201);
    }

    final zoneMatch = RegExp(r'^/inventory/zones/([^/]+)$').firstMatch(path);
    if (zoneMatch != null) {
      final id = zoneMatch.group(1)!;
      final idx = zones.indexWhere((z) => z['id'] == id);
      if (idx < 0) return _notFound();
      if (method == 'GET') return _json(zones[idx]);
      if (method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        zonePatchBodies.add(body);
        final current = zones[idx];
        zones[idx] = _zoneJson(
          id: id,
          name: (body['name'] as String?) ?? current['name'] as String,
          code: body.containsKey('code')
              ? body['code'] as String?
              : current['code'] as String?,
          status: (body['status'] as String?) ?? current['status'] as String,
        );
        return _json(zones[idx]);
      }
    }

    if (path == '/inventory/shelves' && method == 'GET') {
      final zoneId = query['zone_id'];
      final items = zoneId == null
          ? List<Map<String, dynamic>>.from(shelves)
          : [
              for (final s in shelves)
                if (s['zone_id'] == zoneId) s,
            ];
      return _json(items);
    }
    if (path == '/inventory/shelves' && method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      shelfCreateBodies.add(body);
      final shelf = _shelfJson(
        id: 'sh${shelves.length + 1}',
        zoneId: body['zone_id'] as String,
        zoneName: _zoneName(body['zone_id'] as String),
        label: body['label'] as String,
        code: body['code'] as String?,
        position: (body['position'] as num?)?.toInt() ?? 0,
      );
      shelves.add(shelf);
      return _json(shelf, 201);
    }

    final shelfProductItem = RegExp(
      r'^/inventory/shelves/([^/]+)/products/([^/]+)$',
    ).firstMatch(path);
    if (shelfProductItem != null && method == 'DELETE') {
      final shelfId = shelfProductItem.group(1)!;
      final productId = shelfProductItem.group(2)!;
      deleteCalls.add(productId);
      mappings.removeWhere(
        (m) => m['shelf_id'] == shelfId && m['product_id'] == productId,
      );
      return _json({'ok': true});
    }

    final shelfProducts = RegExp(
      r'^/inventory/shelves/([^/]+)/products$',
    ).firstMatch(path);
    if (shelfProducts != null) {
      final shelfId = shelfProducts.group(1)!;
      if (method == 'GET') {
        return _json([
          for (final m in mappings)
            if (m['shelf_id'] == shelfId) m,
        ]);
      }
      if (method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        mapBodies.add(body);
        final alreadyMapped = mappings.any(
          (m) =>
              m['shelf_id'] == shelfId && m['product_id'] == body['product_id'],
        );
        if (alreadyMapped) {
          return _error(
            'CONFLICT',
            'This product is already mapped to this shelf',
            409,
          );
        }
        final product = products.firstWhere(
          (p) => p['id'] == body['product_id'],
        );
        final mapping = _mappingJson(
          id: 'mp${mappings.length + 1}',
          shelfId: shelfId,
          productId: body['product_id'] as String,
          productName: product['name'] as String,
          sku: product['sku'] as String?,
          position: (body['position'] as num?)?.toInt() ?? 0,
          isPrimary: body['is_primary'] as bool? ?? false,
        );
        mappings.add(mapping);
        return _json(mapping, 201);
      }
    }

    final shelfMatch = RegExp(r'^/inventory/shelves/([^/]+)$').firstMatch(path);
    if (shelfMatch != null) {
      final id = shelfMatch.group(1)!;
      final idx = shelves.indexWhere((s) => s['id'] == id);
      if (idx < 0) return _notFound();
      if (method == 'GET') return _json(shelves[idx]);
      if (method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        shelfPatchBodies.add(body);
        final current = shelves[idx];
        final newZoneId =
            (body['zone_id'] as String?) ?? current['zone_id'] as String;
        shelves[idx] = _shelfJson(
          id: id,
          zoneId: newZoneId,
          zoneName: _zoneName(newZoneId),
          label: (body['label'] as String?) ?? current['label'] as String,
          code: body.containsKey('code')
              ? body['code'] as String?
              : current['code'] as String?,
          position:
              (body['position'] as num?)?.toInt() ??
              (current['position'] as num).toInt(),
          status: (body['status'] as String?) ?? current['status'] as String,
        );
        return _json(shelves[idx]);
      }
    }

    if (path == '/inventory/expiry' && method == 'GET') {
      final status = query['status'];
      final items = status == null
          ? List<Map<String, dynamic>>.from(expiry)
          : [
              for (final e in expiry)
                if (e['status'] == status) e,
            ];
      return _json(items);
    }
    if (path == '/inventory/expiry' && method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expiryCreateBodies.add(body);
      final product = products.firstWhere((p) => p['id'] == body['product_id']);
      final batch = _expiryJson(
        id: 'eb${expiry.length + 1}',
        productId: body['product_id'] as String,
        productName: product['name'] as String,
        batchCode: body['batch_code'] as String?,
        quantity: (body['quantity'] as num).toString(),
        expiryDate: body['expiry_date'] as String,
        days: 500,
        status: 'normal',
      );
      expiry.add(batch);
      return _json(batch, 201);
    }

    final expiryMatch = RegExp(r'^/inventory/expiry/([^/]+)$').firstMatch(path);
    if (expiryMatch != null) {
      final id = expiryMatch.group(1)!;
      final idx = expiry.indexWhere((e) => e['id'] == id);
      if (idx < 0) return _notFound();
      if (method == 'GET') return _json(expiry[idx]);
      if (method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expiryPatchBodies.add(body);
        final current = expiry[idx];
        expiry[idx] = _expiryJson(
          id: id,
          productId: current['product_id'] as String,
          productName: current['product_name'] as String,
          batchCode:
              (body['batch_code'] as String?) ??
              current['batch_code'] as String?,
          quantity: current['quantity'] as String,
          expiryDate:
              (body['expiry_date'] as String?) ??
              current['expiry_date'] as String,
          days: current['days_remaining'] as int,
          status: current['status'] as String,
        );
        return _json(expiry[idx]);
      }
      if (method == 'DELETE') {
        deleteCalls.add('expiry:$id');
        expiry.removeAt(idx);
        return _json({'ok': true});
      }
    }

    final writeOffMatch = RegExp(
      r'^/inventory/expiry/([^/]+)/write-off$',
    ).firstMatch(path);
    if (writeOffMatch != null && method == 'POST') {
      final id = writeOffMatch.group(1)!;
      final idx = expiry.indexWhere((e) => e['id'] == id);
      if (idx < 0) return _notFound();
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expiryWriteOffBodies.add(body);
      final current = expiry[idx];
      final remaining =
          (double.parse(current['quantity'] as String) -
                  (body['quantity'] as num).toDouble())
              .toStringAsFixed(3);
      expiry[idx] = _expiryJson(
        id: id,
        productId: current['product_id'] as String,
        productName: current['product_name'] as String,
        batchCode: current['batch_code'] as String?,
        quantity: remaining,
        expiryDate: current['expiry_date'] as String,
        days: current['days_remaining'] as int,
        status: current['status'] as String,
      );
      return _json(expiry[idx]);
    }

    return _notFound();
  }

  String? _zoneName(String zoneId) {
    for (final z in zones) {
      if (z['id'] == zoneId) return z['name'] as String;
    }
    return null;
  }
}

Future<void> _login(WidgetTester tester, ApiClient apiClient) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    VisionStockApp(apiClient: apiClient, storage: MemorySessionStorage()),
  );
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextField, 'Email'),
    'owner@test.dev',
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Password'),
    'Passw0rd!',
  );
  await tester.tap(find.text('Sign in'));
  await tester.pumpAndSettle();
}

Future<void> _goToInventory(WidgetTester tester) async {
  await tester.tap(find.text('Inventory'));
  await tester.pumpAndSettle();
}

Future<void> _openZones(WidgetTester tester) async {
  await _goToInventory(tester);
  await tester.tap(find.text('Layout'));
  await tester.pumpAndSettle();
}

Future<void> _openZoneDetail(
  WidgetTester tester, {
  String zoneName = 'Frozen',
}) async {
  await _openZones(tester);
  await tester.tap(find.text(zoneName));
  await tester.pumpAndSettle();
}

Future<void> _openShelfDetail(
  WidgetTester tester, {
  String shelfLabel = 'FZ-A1',
}) async {
  await _openZoneDetail(tester);
  await tester.tap(find.text(shelfLabel));
  await tester.pumpAndSettle();
}

Future<void> _openExpiry(WidgetTester tester) async {
  await _goToInventory(tester);
  await tester.tap(find.text('Expiry'));
  await tester.pumpAndSettle();
}

Future<void> _openMovements(WidgetTester tester) async {
  await _goToInventory(tester);
  await tester.tap(find.text('Movements'));
  await tester.pumpAndSettle();
}

/// Taps the extended floating action button by its visible label.
Future<void> _tapFabLabel(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byType(FloatingActionButton),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => AppCache.instance.clear());

  group('zones', () {
    testWidgets('list renders zones, codes and the inactive tag', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _openZones(tester);

      expect(find.text('Zones'), findsOneWidget);
      expect(find.text('Frozen'), findsOneWidget);
      expect(find.text('Dairy'), findsOneWidget);
      expect(find.text('FZ'), findsOneWidget);
      expect(find.text('DA'), findsOneWidget);
      expect(find.text('Inactive'), findsOneWidget);
    });

    testWidgets('create posts name and code then refreshes the list', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _openZones(tester);

      await tester.tap(find.byTooltip('Add zone'));
      await tester.pumpAndSettle();
      expect(find.text('New zone'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Zone name'),
        'Produce',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Code (optional)'),
        'PR',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(backend.zoneCreateBodies, hasLength(1));
      expect(backend.zoneCreateBodies.single, {
        'name': 'Produce',
        'code': 'PR',
      });
      expect(find.text('Produce'), findsOneWidget);
      expect(find.text('PR'), findsOneWidget);
    });

    testWidgets('edit can rename and deactivate a zone via updateZone', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _openZones(tester);

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(AppCard, 'Frozen'),
          matching: find.byTooltip('Edit zone'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Edit zone'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Zone name'),
        'Cold Storage',
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inactive').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(backend.zonePatchBodies, hasLength(1));
      expect(backend.zonePatchBodies.single['name'], 'Cold Storage');
      expect(backend.zonePatchBodies.single['code'], 'FZ');
      expect(backend.zonePatchBodies.single['status'], 'inactive');

      expect(find.text('Cold Storage'), findsOneWidget);
      expect(find.text('Inactive'), findsNWidgets(2)); // Dairy + renamed Frozen
    });

    testWidgets('zone actions are hidden without manage_layout', (
      tester,
    ) async {
      final backend = _Backend(permissions: _viewOnlyPermissions);
      await _login(tester, backend.client);
      await _openZones(tester);

      expect(find.byTooltip('Add zone'), findsNothing);
      expect(find.byTooltip('Edit zone'), findsNothing);

      await tester.tap(find.text('Frozen'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Add shelf'), findsNothing);
      expect(find.byTooltip('Edit zone'), findsNothing);
      expect(find.byTooltip('Edit shelf'), findsNothing);
    });

    testWidgets('zone load failure shows retry and recovers', (tester) async {
      final backend = _Backend(failZones: true);
      await _login(tester, backend.client);
      await _openZones(tester);

      expect(find.text('Request failed (500)'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('Frozen'), findsOneWidget);
      expect(find.text('Dairy'), findsOneWidget);
    });
  });

  group('shelves', () {
    testWidgets('create posts zone id label and position then refreshes', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _openZoneDetail(tester);

      expect(find.text('0 shelves · code FZ'), findsOneWidget);
      await tester.tap(find.byTooltip('Add shelf'));
      await tester.pumpAndSettle();
      expect(find.text('New shelf'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Shelf label'),
        'FZ-A1',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(backend.shelfCreateBodies, hasLength(1));
      expect(backend.shelfCreateBodies.single, {
        'zone_id': 'z1',
        'label': 'FZ-A1',
        'position': 0,
      });
      expect(find.text('FZ-A1'), findsOneWidget);
      expect(find.text('1 shelves · code FZ'), findsOneWidget);
    });

    testWidgets('edit updates label and status via updateShelf', (
      tester,
    ) async {
      final backend = _Backend(seedShelf: true);
      await _login(tester, backend.client);
      await _openZoneDetail(tester);

      expect(find.text('1 shelves · code FZ'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(AppCard, 'FZ-A1'),
          matching: find.byTooltip('Edit shelf'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Edit shelf'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Shelf label'),
        'FZ-A1-2',
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inactive').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(backend.shelfPatchBodies, hasLength(1));
      expect(backend.shelfPatchBodies.single['zone_id'], 'z1');
      expect(backend.shelfPatchBodies.single['label'], 'FZ-A1-2');
      expect(backend.shelfPatchBodies.single['code'], 'S-01');
      expect(backend.shelfPatchBodies.single['position'], 0);
      expect(backend.shelfPatchBodies.single['status'], 'inactive');

      await tester.tap(find.text('FZ-A1-2'));
      await tester.pumpAndSettle();
      expect(find.text('Inactive'), findsOneWidget); // shelf detail badge
    });

    testWidgets('edit can re-zone the shelf by sending the new zone id', (
      tester,
    ) async {
      final backend = _Backend(seedShelf: true);
      await _login(tester, backend.client);
      await _openShelfDetail(tester);

      expect(find.textContaining('Frozen · position 0'), findsOneWidget);

      await tester.tap(find.byTooltip('Edit shelf'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dairy').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(backend.shelfPatchBodies, hasLength(1));
      expect(backend.shelfPatchBodies.single['zone_id'], 'z2');
      expect(find.textContaining('Dairy · position 0'), findsOneWidget);
    });

    testWidgets('shelf actions are hidden without manage_layout', (
      tester,
    ) async {
      final backend = _Backend(
        permissions: _viewOnlyPermissions,
        seedShelf: true,
      );
      await _login(tester, backend.client);
      await _openShelfDetail(tester);

      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byTooltip('Edit shelf'), findsNothing);
      expect(find.byTooltip('Remove'), findsNothing);
      expect(find.text('Map product'), findsNothing);
    });
  });

  group('shelf-product mapping', () {
    testWidgets('map product posts the mapping and shows it on the shelf', (
      tester,
    ) async {
      final backend = _Backend(seedShelf: true);
      await _login(tester, backend.client);
      await _openShelfDetail(tester);

      expect(find.text('No products mapped'), findsOneWidget);
      await _tapFabLabel(tester, 'Map product');
      expect(find.text('Select product'), findsOneWidget);

      await tester.tap(find.text('Cola 330ml'));
      await tester.pumpAndSettle();

      expect(backend.mapBodies, hasLength(1));
      expect(backend.mapBodies.single, {
        'product_id': 'p1',
        'position': 0,
        'is_primary': false,
      });
      expect(find.text('Product added to shelf'), findsOneWidget);
      expect(find.text('Products (1)'), findsOneWidget);
      expect(find.text('Cola 330ml'), findsOneWidget);
    });

    testWidgets('mapping an already-mapped product is rejected clearly', (
      tester,
    ) async {
      final backend = _Backend(seedShelf: true, seedMapping: true);
      await _login(tester, backend.client);
      await _openShelfDetail(tester);

      expect(find.text('Products (1)'), findsOneWidget);
      await _tapFabLabel(tester, 'Map product');
      await tester.tap(find.text('Cola 330ml'));
      await tester.pumpAndSettle();

      expect(
        find.text('This product is already mapped to this shelf'),
        findsOneWidget,
      );
      expect(backend.mapBodies, hasLength(1));
      expect(find.text('Products (1)'), findsOneWidget);
      expect(find.text('Cola 330ml'), findsOneWidget);
    });

    testWidgets('unmap requires confirmation and removes the mapping', (
      tester,
    ) async {
      final backend = _Backend(seedShelf: true, seedMapping: true);
      await _login(tester, backend.client);
      await _openShelfDetail(tester);

      // Cancel first: nothing is removed.
      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Remove from shelf?'), findsOneWidget);
      expect(
        find.text('Cola 330ml will no longer be mapped to FZ-A1.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(backend.deleteCalls, isEmpty);
      expect(find.text('Cola 330ml'), findsOneWidget);

      // Confirm the second time: mapping is removed.
      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(backend.deleteCalls, ['p1']);
      expect(find.text('No products mapped'), findsOneWidget);
      expect(find.text('Products (0)'), findsOneWidget);
    });

    testWidgets('mapping actions are hidden without manage_layout', (
      tester,
    ) async {
      final backend = _Backend(
        permissions: _viewOnlyPermissions,
        seedShelf: true,
        seedMapping: true,
      );
      await _login(tester, backend.client);
      await _openShelfDetail(tester);

      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byTooltip('Remove'), findsNothing);
      expect(find.text('Map product'), findsNothing);
      expect(find.text('Cola 330ml'), findsOneWidget); // still viewable
    });
  });

  group('expiry', () {
    testWidgets('list renders batches with days remaining and past', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _openExpiry(tester);

      expect(find.text('Expiry tracking'), findsOneWidget);
      expect(find.text('3 batches'), findsOneWidget);
      expect(find.text('Cola 330ml'), findsOneWidget);
      expect(find.text('Milk 1L'), findsOneWidget);
      expect(find.text('Yogurt 500g'), findsOneWidget);
      expect(find.text('500d left'), findsOneWidget);
      expect(find.text('3d past'), findsOneWidget);
      expect(find.text('5d past'), findsOneWidget);
    });

    testWidgets('create posts product quantity date and code then refreshes', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _openExpiry(tester);

      await tester.tap(find.byTooltip('Add expiry batch'));
      await tester.pumpAndSettle();
      expect(find.text('Select product'), findsOneWidget);
      await tester.tap(find.text('Cola 330ml'));
      await tester.pumpAndSettle();

      expect(find.text('Add expiry batch'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Quantity'), '24');
      await tester.enterText(
        find.widgetWithText(TextField, 'Batch code (optional)'),
        'LOT-1',
      );
      await tester.tap(find.text('Pick date'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Add batch'));
      await tester.tap(find.text('Add batch'));
      await tester.pumpAndSettle();

      expect(backend.expiryCreateBodies, hasLength(1));
      final body = backend.expiryCreateBodies.single;
      expect(body['product_id'], 'p1');
      expect(body['quantity'], 24.0);
      expect(body['batch_code'], 'LOT-1');
      expect(body['expiry_date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));

      expect(find.text('Expiry batch added'), findsOneWidget);
      expect(find.textContaining('LOT-1'), findsOneWidget);
    });

    testWidgets('edit updates the batch code via updateExpiryBatch', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _openExpiry(tester);

      await tester.tap(find.text('Cola 330ml'));
      await tester.pumpAndSettle();
      expect(find.text('Expiry batch'), findsOneWidget);

      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Edit expiry batch'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Batch code (optional)'),
        'LOT-A2',
      );
      await tester.ensureVisible(find.text('Save changes'));
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();

      expect(backend.expiryPatchBodies, hasLength(1));
      expect(backend.expiryPatchBodies.single['batch_code'], 'LOT-A2');
      expect(find.text('Expiry batch updated'), findsOneWidget);
      expect(find.text('LOT-A2'), findsOneWidget);
    });

    testWidgets('delete confirms then removes the batch', (tester) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _openExpiry(tester);

      // eb2 is drained (quantity 0), so deletion is allowed.
      await tester.tap(find.text('Milk 1L'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Delete batch'));
      await tester.tap(find.text('Delete batch'));
      await tester.pumpAndSettle();

      expect(find.text('Delete expiry batch?'), findsOneWidget);
      expect(
        find.text(
          'Only batches with zero remaining quantity can be deleted. '
          'Drain the batch via Adjust Stock first.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(backend.deleteCalls, ['expiry:eb2']);
      // Deleting a drained batch must never mutate stock.
      expect(backend.stockPatchBodies, isEmpty);
      expect(find.text('Expiry batch deleted'), findsOneWidget);
      expect(find.text('Milk 1L'), findsNothing);
      expect(find.text('Cola 330ml'), findsOneWidget);
    });

    testWidgets('delete is disabled while the batch still has stock', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _openExpiry(tester);

      // eb1 still holds 12 units; the Delete action must be disabled.
      await tester.tap(find.text('Cola 330ml'));
      await tester.pumpAndSettle();
      expect(find.text('Expiry batch'), findsOneWidget);

      await tester.ensureVisible(find.text('Delete batch'));
      final deleteButton = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Delete batch'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(deleteButton.onPressed, isNull);

      await tester.tap(find.text('Delete batch'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Delete expiry batch?'), findsNothing);
      expect(backend.deleteCalls, isEmpty);
      expect(
        find.text('Drain the batch to zero via Adjust Stock before deleting.'),
        findsOneWidget,
      );
    });

    testWidgets('stock detail batch card opens the expiry batch detail', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _goToInventory(tester);

      await tester.tap(find.widgetWithText(AppCard, 'Cola 330ml'));
      await tester.pumpAndSettle();
      expect(find.text('Expiry batches'), findsOneWidget);
      expect(find.text('LOT-A'), findsOneWidget);

      await tester.tap(find.text('LOT-A'));
      await tester.pumpAndSettle();
      expect(find.text('Expiry batch'), findsOneWidget);
      expect(find.text('12 in batch'), findsOneWidget);
    });

    testWidgets('Near expiry tile opens the expiry list pre-filtered', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _goToInventory(tester);

      await tester.tap(
        find.descendant(
          of: find.byType(GridView),
          matching: find.widgetWithText(AppCard, 'Near expiry'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Expiry tracking'), findsOneWidget);
      // Both seeded batches are normal/expired, so the near-expiry filter is empty.
      expect(find.text('0 batches'), findsOneWidget);
      expect(find.text('No expiry batches'), findsOneWidget);
    });

    testWidgets('Expired tile opens the expiry list pre-filtered to expired', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _goToInventory(tester);

      await tester.tap(
        find.descendant(
          of: find.byType(GridView),
          matching: find.widgetWithText(AppCard, 'Expired'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Expiry tracking'), findsOneWidget);
      expect(find.text('2 batches'), findsOneWidget);
      expect(find.text('Milk 1L'), findsOneWidget);
      expect(find.text('Yogurt 500g'), findsOneWidget);
      expect(find.text('Cola 330ml'), findsNothing);
    });

    testWidgets('hide drained toggle filters out zero-quantity batches', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _openExpiry(tester);

      // Default OFF: drained batches remain visible.
      expect(find.text('3 batches'), findsOneWidget);
      expect(find.text('Milk 1L'), findsOneWidget);

      await tester.tap(find.text('Hide drained batches'));
      await tester.pumpAndSettle();

      expect(find.text('2 batches'), findsOneWidget);
      expect(find.text('Cola 330ml'), findsOneWidget);
      expect(find.text('Yogurt 500g'), findsOneWidget);
      expect(find.text('Milk 1L'), findsNothing);

      // Toggle back off restores the drained batch.
      await tester.tap(find.text('Hide drained batches'));
      await tester.pumpAndSettle();
      expect(find.text('3 batches'), findsOneWidget);
      expect(find.text('Milk 1L'), findsOneWidget);
    });

    testWidgets('expiry actions are hidden without manage_expiry', (
      tester,
    ) async {
      final backend = _Backend(permissions: _viewOnlyPermissions);
      await _login(tester, backend.client);
      await _openExpiry(tester);

      expect(find.byTooltip('Add expiry batch'), findsNothing);

      await tester.tap(find.text('Cola 330ml'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Edit'), findsNothing);
      expect(find.text('Edit batch'), findsNothing);
      expect(find.text('Delete batch'), findsNothing);

      // eb3 is expired with stock: without manage_expiry the write-off
      // action must still be hidden.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yogurt 500g'));
      await tester.pumpAndSettle();
      expect(find.text('Write off stock'), findsNothing);
      expect(find.text('Edit batch'), findsNothing);
      expect(find.text('Delete batch'), findsNothing);
    });

    testWidgets('write off drains the batch and enables delete', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _openExpiry(tester);

      await tester.tap(find.text('Yogurt 500g'));
      await tester.pumpAndSettle();
      expect(find.text('Expiry batch'), findsOneWidget);
      expect(find.text('8 in batch'), findsOneWidget);

      await tester.ensureVisible(find.text('Write off stock'));
      await tester.tap(find.text('Write off stock'));
      await tester.pumpAndSettle();

      expect(find.text('Write off stock?'), findsOneWidget);
      // Quantity is prefilled with the full batch quantity; reason is required.
      await tester.enterText(
        find.widgetWithText(TextField, 'Reason'),
        'Spoiled beyond use',
      );
      await tester.tap(find.text('Write off'));
      await tester.pumpAndSettle();

      expect(backend.expiryWriteOffBodies, hasLength(1));
      expect(backend.expiryWriteOffBodies.single, {
        'quantity': 8.0,
        'reason': 'Spoiled beyond use',
      });
      expect(find.text('Stock written off'), findsOneWidget);
      expect(find.text('0 in batch'), findsOneWidget);

      // The drained batch can now be deleted.
      final deleteButton = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Delete batch'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(deleteButton.onPressed, isNotNull);
    });

    testWidgets('write off requires a valid quantity and reason', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _openExpiry(tester);

      await tester.tap(find.text('Yogurt 500g'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Write off stock'));
      await tester.tap(find.text('Write off stock'));
      await tester.pumpAndSettle();

      // Empty reason is rejected before any request is sent.
      await tester.tap(find.text('Write off'));
      await tester.pumpAndSettle();
      expect(find.text('Reason is required'), findsOneWidget);
      expect(backend.expiryWriteOffBodies, isEmpty);

      // Over-available quantity is rejected.
      await tester.enterText(find.widgetWithText(TextField, 'Quantity'), '99');
      await tester.enterText(
        find.widgetWithText(TextField, 'Reason'),
        'Too much',
      );
      await tester.tap(find.text('Write off'));
      await tester.pumpAndSettle();
      expect(
        find.text('Cannot write off more than the available quantity'),
        findsOneWidget,
      );
      expect(backend.expiryWriteOffBodies, isEmpty);

      // Zero is rejected.
      await tester.enterText(find.widgetWithText(TextField, 'Quantity'), '0');
      await tester.tap(find.text('Write off'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a quantity greater than zero'), findsOneWidget);
      expect(backend.expiryWriteOffBodies, isEmpty);
    });

    testWidgets('write off is only offered for expired batches with stock', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _openExpiry(tester);

      // eb1 Cola is normal (not expired): no write-off action.
      await tester.tap(find.text('Cola 330ml'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Edit batch'));
      expect(find.text('Write off stock'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();

      // eb3 Yogurt is expired with stock: write-off is offered.
      await tester.tap(find.text('Yogurt 500g'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Write off stock'));
      expect(find.text('Write off stock'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      // eb2 Milk is expired but drained: no write-off action.
      await tester.tap(find.text('Milk 1L'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Delete batch'));
      expect(find.text('Write off stock'), findsNothing);
    });
  });

  group('movements', () {
    testWidgets('list renders movement types and total', (tester) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _openMovements(tester);

      expect(find.text('Stock movements'), findsOneWidget);
      expect(find.text('2 movements'), findsOneWidget);
      expect(find.text('Cola 330ml'), findsOneWidget);
      expect(find.text('Water 500ml'), findsOneWidget);
      expect(find.text('Opening'), findsNWidgets(2)); // chip + badge
      expect(find.text('Adjustment'), findsOneWidget); // badge
      expect(find.text('Adjustments'), findsOneWidget); // chip
      expect(find.text('Write offs'), findsOneWidget); // chip
    });

    testWidgets('filter chip narrows the list by movement type', (
      tester,
    ) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _openMovements(tester);

      await tester.tap(find.text('Adjustments'));
      await tester.pumpAndSettle();

      expect(backend.lastMovementsType, 'ADJUSTMENT');
      expect(find.text('1 movements'), findsOneWidget);
      expect(find.text('Water 500ml'), findsOneWidget);
      expect(find.text('Cola 330ml'), findsNothing);
    });

    testWidgets(
      'write-offs chip requests WRITE_OFF and shows the empty state',
      (tester) async {
        final backend = _Backend();
        await _login(tester, backend.client);
        await _openMovements(tester);

        await tester.drag(find.text('All'), const Offset(-400, 0));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Write offs'));
        await tester.pumpAndSettle();

        expect(backend.lastMovementsType, 'WRITE_OFF');
        expect(find.text('0 movements'), findsOneWidget);
        expect(find.text('No movements yet'), findsOneWidget);
      },
    );

    testWidgets('movements failure shows retry and recovers', (tester) async {
      final backend = _Backend(failMovements: true);
      await _login(tester, backend.client);
      await _openMovements(tester);

      expect(find.text('Request failed (500)'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('2 movements'), findsOneWidget);
      expect(find.text('Cola 330ml'), findsOneWidget);
    });

    testWidgets('movements button is hidden without view_movements', (
      tester,
    ) async {
      final backend = _Backend(permissions: _viewOnlyPermissions);
      await _login(tester, backend.client);
      await _goToInventory(tester);

      expect(find.text('Movements'), findsNothing);
    });
  });

  group('overview', () {
    testWidgets(
      'Total products tile shows every product regardless of status',
      (tester) async {
        final backend = _Backend();
        await _login(tester, backend.client);
        await _goToInventory(tester);

        expect(find.text('Cola 330ml'), findsOneWidget);
        expect(find.text('Water 500ml'), findsOneWidget);

        await tester.tap(find.text('Total products'));
        await tester.pumpAndSettle();

        // Regression for B1: the tile must not apply the healthy filter.
        expect(find.text('Cola 330ml'), findsOneWidget);
        expect(find.text('Water 500ml'), findsOneWidget);
      },
    );

    testWidgets('Healthy tile still filters to healthy stock', (tester) async {
      final backend = _Backend();
      await _login(tester, backend.client);
      await _goToInventory(tester);

      await tester.tap(
        find.descendant(
          of: find.byType(GridView),
          matching: find.widgetWithText(AppCard, 'Healthy'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Cola 330ml'), findsOneWidget);
      expect(find.text('Water 500ml'), findsNothing);
    });
  });

  group('product picker', () {
    testWidgets(
      'picker failure shows a friendly message without stack traces',
      (tester) async {
        final backend = _Backend(seedShelf: true, failProducts: true);
        await _login(tester, backend.client);
        await _openShelfDetail(tester);

        await _tapFabLabel(tester, 'Map product');

        expect(
          find.text('Cannot reach the server. Check your connection.'),
          findsOneWidget,
        );
        expect(find.textContaining('internal detail'), findsNothing);
        expect(find.textContaining('Exception'), findsNothing);
      },
    );
  });
}
