import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/session_store.dart';
import 'package:visionstock_mobile/main.dart';

const _allPermissions = [
  'products.view',
  'products.manage',
  'suppliers.view',
  'inventory.view',
  'inventory.adjust',
  'inventory.manage_layout',
  'inventory.view_movements',
  'inventory.manage_expiry',
];

const _store = {'id': 's1', 'name': 'Downtown', 'timezone': 'UTC', 'currency': 'USD'};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _page(List<Map<String, dynamic>> items) => {
      'items': items,
      'total': items.length,
      'page': 1,
      'page_size': 30,
      'pages': items.isEmpty ? 0 : 1,
    };

Map<String, dynamic> _stockJson({
  String id = 'p1',
  String name = 'Cola 330ml',
  String sku = 'SKU-1',
  String status = 'healthy',
  String quantity = '100.000',
  bool hasOpening = true,
}) =>
    {
      'product_id': id,
      'product_name': name,
      'sku': sku,
      'barcode': null,
      'unit': 'pcs',
      'category_id': null,
      'category_name': null,
      'cost_price': '0.80',
      'selling_price': '1.50',
      'reorder_point': '10.000',
      'reorder_quantity': '50.000',
      'expiry_tracking_enabled': false,
      'quantity': quantity,
      'reserved_quantity': '0.000',
      'available_quantity': quantity,
      'stock_status': status,
      'value': '80.00',
      'has_opening': hasOpening,
      'nearest_expiry_date': null,
      'nearest_expiry_status': null,
      'updated_at': '2026-01-01T00:00:00Z',
      'shelves': <Object>[],
      'expiry_batches': <Object>[],
      'recent_movements': <Object>[],
    };

Map<String, dynamic> _summaryJson() => {
      'total_products': 2,
      'total_value': '180.00',
      'healthy': 1,
      'low_stock': 1,
      'out_of_stock': 0,
      'near_expiry': 0,
      'expired': 0,
    };

ApiClient _apiClient({List<String> permissions = _allPermissions}) {
  final summary = _summaryJson();
  final healthy = _stockJson(id: 'p1', name: 'Cola 330ml', status: 'healthy');
  final low = _stockJson(id: 'p2', name: 'Water 500ml', status: 'low_stock', quantity: '5.000');
  var adjustments = 0;
  final loginPayload = {
    'access_token': 'a-token',
    'refresh_token': 'r-token',
    'expires_in': 900,
    'user': {'id': 'u1', 'email': 'owner@test.dev', 'name': 'Owner', 'status': 'active'},
    'permissions': permissions,
    'stores': [_store],
  };
  final mePayload = {
    'user': {'id': 'u1', 'email': 'owner@test.dev', 'name': 'Owner', 'status': 'active'},
    'permissions': permissions,
    'stores': [_store],
  };

  return ApiClient(
    baseUrl: 'http://test',
    client: MockClient((request) async {
      final path = request.url.path;
      final query = request.url.queryParameters;

      if (path == '/auth/login') return _json(loginPayload);
      if (path == '/auth/me') return _json(mePayload);

      if (path == '/inventory/stock/summary') return _json(summary);

      if (path == '/inventory/stock') {
        final filter = query['stock_status'];
        final items = switch (filter) {
          'low_stock' => [low],
          'healthy' => [healthy],
          null => [healthy, low],
          _ => [low, healthy],
        };
        return _json(_page(items));
      }

      final stockMatch = RegExp(r'^/inventory/stock/([^/]+)$').firstMatch(path);
      if (stockMatch != null && request.method == 'GET') {
        final id = stockMatch.group(1)!;
        return _json(_stockJson(id: id, name: id == 'p2' ? 'Water 500ml' : 'Cola 330ml', hasOpening: id != 'p2'));
      }

      if (path.endsWith('/opening')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return _json(_stockJson(id: 'p2', name: 'Water 500ml', hasOpening: true, quantity: (body['quantity'] as num).toStringAsFixed(3)));
      }

      if (stockMatch != null && request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final delta = (body['delta'] as num).toDouble();
        final current = 100.0;
        adjustments += 1;
        final updated = _stockJson(
          id: stockMatch.group(1)!,
          quantity: (current + delta).toStringAsFixed(3),
          status: current + delta <= 0 ? 'out_of_stock' : 'healthy',
        );
        updated['recent_movements'] = [
          {
            'id': 'm$adjustments',
            'movement_type': 'ADJUSTMENT',
            'quantity_delta': delta.toStringAsFixed(3),
            'resulting_quantity': (current + delta).toStringAsFixed(3),
            'reference_type': null,
            'reference_id': null,
            'notes': body['reason'],
            'created_by': 'u1',
            'created_by_name': 'Owner',
            'created_at': '2026-01-02T00:00:00Z',
          },
        ];
        return _json(updated);
      }

      if (path == '/inventory/movements') {
        return _json(_page(const []));
      }

      if (path == '/inventory/zones') return _json(const <Object>[]);
      if (path == '/inventory/shelves') return _json(const <Object>[]);
      if (path == '/inventory/expiry') return _json(const <Object>[]);

      return http.Response('{"detail": {"code": "NOT_FOUND", "message": "Not found"}}', 404);
    }),
  );
}

Future<void> _login(WidgetTester tester, ApiClient apiClient) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(VisionStockApp(apiClient: apiClient, storage: MemorySessionStorage()));
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextField, 'Email'), 'owner@test.dev');
  await tester.enterText(find.widgetWithText(TextField, 'Password'), 'Passw0rd!');
  await tester.tap(find.text('Sign in'));
  await tester.pumpAndSettle();
}

Future<void> _openInventoryTab(WidgetTester tester) async {
  await tester.tap(find.text('Inventory'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('inventory tab renders summary metrics and stock list', (tester) async {
    await _login(tester, _apiClient());
    await _openInventoryTab(tester);

    expect(find.text('Total products'), findsOneWidget);
    expect(find.text('Low stock'), findsWidgets); // tile + filter chip
    expect(find.text('Out of stock'), findsWidgets);
    expect(find.text('Cola 330ml'), findsOneWidget);
    expect(find.text('Water 500ml'), findsOneWidget);
    expect(find.text('2 products'), findsOneWidget);
  });

  testWidgets('low stock filter narrows the list', (tester) async {
    await _login(tester, _apiClient());
    await _openInventoryTab(tester);

    await tester.tap(find.widgetWithText(FilterChip, 'Low stock').first);
    await tester.pumpAndSettle();

    expect(find.text('Water 500ml'), findsOneWidget);
    expect(find.text('Cola 330ml'), findsNothing);
  });

  testWidgets('inventory tab hidden without inventory.view', (tester) async {
    final api = _apiClient(permissions: ['products.view', 'products.manage']);
    await _login(tester, api);

    expect(find.text('Inventory'), findsNothing);
    expect(find.text('Products'), findsWidgets);
  });

  testWidgets('adjust flow: signed delta shows resulting quantity and posts', (tester) async {
    await _login(tester, _apiClient());
    await _openInventoryTab(tester);

    await tester.tap(find.text('Cola 330ml'));
    await tester.pumpAndSettle();

    expect(find.text('100 pcs'), findsWidgets);
    await tester.tap(find.text('Adjust stock'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Adjustment (signed)'), '-10');
    await tester.enterText(find.widgetWithText(TextField, 'Reason'), 'Damaged');
    await tester.pumpAndSettle();

    expect(find.text('90 pcs'), findsWidgets); // live resulting quantity

    await tester.tap(find.text('Apply adjustment'));
    await tester.pumpAndSettle();

    expect(find.text('90 pcs'), findsWidgets); // updated from response
    expect(find.text('Damaged'), findsOneWidget); // movement note visible
  });

  testWidgets('no adjust permission hides adjust actions', (tester) async {
    final api = _apiClient(permissions: [
      'products.view',
      'inventory.view',
    ]);
    await _login(tester, api);
    await _openInventoryTab(tester);

    await tester.tap(find.text('Cola 330ml'));
    await tester.pumpAndSettle();

    expect(find.text('Adjust stock'), findsNothing);
    expect(find.text('Set opening stock'), findsNothing);
  });

  testWidgets('opening stock flow posts and refreshes', (tester) async {
    await _login(tester, _apiClient());
    await _openInventoryTab(tester);

    await tester.tap(find.text('Water 500ml'));
    await tester.pumpAndSettle();

    // Water (p2) has no opening stock yet, so the action is "Set opening stock".
    expect(find.text('Set opening stock'), findsOneWidget);
    await tester.tap(find.text('Set opening stock'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Opening quantity'), '50');
    await tester.tap(find.text('Save opening stock'));
    await tester.pumpAndSettle();

    // After POST /opening the detail refreshes to has_opening=true → adjust action.
    expect(find.text('Adjust stock'), findsOneWidget);
    expect(find.text('50 pcs'), findsWidgets);
  });
}
