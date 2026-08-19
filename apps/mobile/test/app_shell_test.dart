import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/session_store.dart';
import 'package:visionstock_mobile/features/home/app_shell.dart';
import 'package:visionstock_mobile/main.dart';

const _loginPayload = {
  'access_token': 'a-token',
  'refresh_token': 'r-token',
  'expires_in': 900,
  'user': {'id': 'u1', 'email': 'owner@test.dev', 'name': 'Owner', 'status': 'active'},
  'permissions': ['products.view', 'products.manage', 'suppliers.view', 'suppliers.manage'],
  'stores': [
    {'id': 's1', 'name': 'Downtown', 'timezone': 'UTC', 'currency': 'USD'},
  ],
};

const _mePayload = {
  'user': {'id': 'u1', 'email': 'owner@test.dev', 'name': 'Owner', 'status': 'active'},
  'permissions': ['products.view', 'products.manage', 'suppliers.view', 'suppliers.manage'],
  'stores': [
    {'id': 's1', 'name': 'Downtown', 'timezone': 'UTC', 'currency': 'USD'},
  ],
};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _page(List<Map<String, dynamic>> items) => {
      'items': items,
      'total': items.length,
      'page': 1,
      'page_size': 30,
      'pages': items.isEmpty ? 0 : 1,
    };

Map<String, dynamic> _productJson() => {
      'id': 'p1',
      'store_id': 's1',
      'category_id': null,
      'category_name': null,
      'sku': 'SKU-1',
      'barcode': null,
      'name': 'Cola 330ml',
      'description': null,
      'unit': 'pcs',
      'cost_price': 0.8,
      'selling_price': 1.5,
      'reorder_point': 10,
      'reorder_quantity': 50,
      'expiry_tracking_enabled': false,
      'image_url': null,
      'status': 'active',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

/// Mock backend wired to a `products` responder so each test controls the
/// product list response.
ApiClient _apiClient({required Future<http.Response> Function(http.Request) products}) =>
    ApiClient(
      baseUrl: 'http://test',
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/auth/login':
            return _json(_loginPayload);
          case '/auth/me':
            return _json(_mePayload);
          case '/products':
            return products(request);
          default:
            return http.Response('{}', 200);
        }
      }),
    );

Future<void> _login(WidgetTester tester, ApiClient apiClient) async {
  await tester.pumpWidget(VisionStockApp(apiClient: apiClient, storage: MemorySessionStorage()));
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextField, 'Email'), 'owner@test.dev');
  await tester.enterText(find.widgetWithText(TextField, 'Password'), 'Passw0rd!');
  await tester.tap(find.text('Sign in'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tab shell shows exactly one AppBar (no nested/duplicate bars)', (tester) async {
    final api = _apiClient(products: (_) async => _json(_page([_productJson()])));
    await _login(tester, api);

    expect(find.byType(AppShell), findsOneWidget);
    // The shell owns the single AppBar; the Products tab body has none.
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('Products'), findsWidgets); // shell title + nav destination

    // List content renders inside the tab body.
    expect(find.text('Cola 330ml'), findsOneWidget);
    expect(find.text('\$1.50'), findsOneWidget);
    expect(find.byTooltip('Add product'), findsOneWidget);
  });

  testWidgets('products empty state shows guidance and add action', (tester) async {
    final api = _apiClient(products: (_) async => _json(_page(const [])));
    await _login(tester, api);

    expect(find.text('No products found'), findsOneWidget);
    expect(find.text('Add your first product to start stocking the store.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add product'), findsOneWidget);
  });

  testWidgets('products error state shows message and retry', (tester) async {
    final api = _apiClient(
      products: (_) async => _json(
        {
          'detail': {'code': 'HTTP_500', 'message': 'Request failed (500)'},
        },
        500,
      ),
    );
    await _login(tester, api);

    expect(find.text('Request failed (500)'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
