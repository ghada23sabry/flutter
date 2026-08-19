import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/session_store.dart';
import 'package:visionstock_mobile/main.dart';

// View-only permissions: keeps list screens FAB-free so the default
// FloatingActionButton Hero tag cannot collide across the IndexedStack tabs
// while a detail route transition runs.
const _permissions = [
  'products.view',
  'suppliers.view',
];

const _store = {
  'id': 's1',
  'name': 'Downtown',
  'timezone': 'UTC',
  'currency': 'USD',
};

const _loginPayload = {
  'access_token': 'a-token',
  'refresh_token': 'r-token',
  'expires_in': 900,
  'user': {
    'id': 'u1',
    'email': 'owner@test.dev',
    'name': 'Owner',
    'status': 'active',
  },
  'permissions': _permissions,
  'stores': [_store],
};

const _mePayload = {
  'user': {
    'id': 'u1',
    'email': 'owner@test.dev',
    'name': 'Owner',
    'status': 'active',
  },
  'permissions': _permissions,
  'stores': [_store],
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _page(List<Map<String, dynamic>> items) => {
  'items': items,
  'total': items.length,
  'page': 1,
  'page_size': 30,
  'pages': items.isEmpty ? 0 : 1,
};

Map<String, dynamic> _productJson({
  String id = 'p1',
  String name = 'Cola 330ml',
}) => {
  'id': id,
  'store_id': 's1',
  'category_id': null,
  'category_name': null,
  'sku': 'SKU-1',
  'barcode': null,
  'name': name,
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

Map<String, dynamic> _supplierJson({
  String id = 'sup1',
  String name = 'Acme Supplies',
}) => {
  'id': id,
  'name': name,
  'contact_name': 'Jane Doe',
  'phone': '555-0100',
  'email': 'jane@acme.test',
  'address': '1 Main St',
  'notes': null,
  'status': 'active',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
};

http.Response _notFound(String message) => _json({
  'detail': {'code': 'NOT_FOUND', 'message': message},
}, 404);

/// Mock backend: catalog lists resolve normally; detail endpoints can be
/// overridden per test to exercise error and retry paths.
ApiClient _apiClient({
  Future<http.Response> Function(http.Request)? productDetail,
  Future<http.Response> Function(http.Request)? supplierDetail,
}) => ApiClient(
  baseUrl: 'http://test',
  client: MockClient((request) async {
    final path = request.url.path;

    if (path == '/auth/login') return _json(_loginPayload);
    if (path == '/auth/me') return _json(_mePayload);

    if (path == '/products') return _json(_page([_productJson()]));
    if (path == '/products/p1/suppliers') return _json(const <Object>[]);
    final productDetailMatch = RegExp(r'^/products/([^/]+)$').firstMatch(path);
    if (productDetailMatch != null) {
      if (productDetail != null) return productDetail(request);
      return _json(_productJson(id: productDetailMatch.group(1)!));
    }

    if (path == '/suppliers') return _json(_page([_supplierJson()]));
    if (path == '/suppliers/sup1/products') return _json(const <Object>[]);
    final supplierDetailMatch = RegExp(
      r'^/suppliers/([^/]+)$',
    ).firstMatch(path);
    if (supplierDetailMatch != null) {
      if (supplierDetail != null) return supplierDetail(request);
      return _json(_supplierJson(id: supplierDetailMatch.group(1)!));
    }

    return http.Response(
      '{"detail": {"code": "NOT_FOUND", "message": "Not found"}}',
      404,
    );
  }),
);

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

Future<void> _openProductDetail(WidgetTester tester) async {
  await tester.tap(find.text('Cola 330ml'));
  await tester.pumpAndSettle();
}

Future<void> _openSupplierDetail(WidgetTester tester) async {
  await tester.tap(find.text('Suppliers'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Acme Supplies'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('product detail leaves LoadingState after successful load', (
    tester,
  ) async {
    await _login(tester, _apiClient());
    await _openProductDetail(tester);

    expect(find.text('Loading product…'), findsNothing);
    expect(find.text('Cola 330ml'), findsWidgets);
    expect(find.text('Cost price'), findsOneWidget);
    expect(find.text('Selling price'), findsOneWidget);
    expect(
      find.text('No suppliers linked to this product yet.'),
      findsOneWidget,
    );
  });

  testWidgets('supplier detail leaves LoadingState after successful load', (
    tester,
  ) async {
    await _login(tester, _apiClient());
    await _openSupplierDetail(tester);

    expect(find.text('Loading supplier…'), findsNothing);
    expect(find.text('Products supplied'), findsOneWidget);
    expect(find.text('No products yet'), findsOneWidget);
    expect(find.text('jane@acme.test'), findsOneWidget);
  });

  testWidgets('product detail failed load shows ErrorState', (tester) async {
    final api = _apiClient(
      productDetail: (_) async => _notFound('Product not found'),
    );
    await _login(tester, api);
    await _openProductDetail(tester);

    expect(find.text('Loading product…'), findsNothing);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Product not found'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('supplier detail failed load shows ErrorState', (tester) async {
    final api = _apiClient(
      supplierDetail: (_) async => _notFound('Supplier not found'),
    );
    await _login(tester, api);
    await _openSupplierDetail(tester);

    expect(find.text('Loading supplier…'), findsNothing);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Supplier not found'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('product detail retry recovers after a failed load', (
    tester,
  ) async {
    var calls = 0;
    final api = _apiClient(
      productDetail: (_) async {
        calls++;
        if (calls == 1) return _notFound('Product not found');
        return _json(_productJson());
      },
    );
    await _login(tester, api);
    await _openProductDetail(tester);

    expect(find.text('Product not found'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Product not found'), findsNothing);
    expect(find.text('Cost price'), findsOneWidget);
  });

  testWidgets('supplier detail retry recovers after a failed load', (
    tester,
  ) async {
    var calls = 0;
    final api = _apiClient(
      supplierDetail: (_) async {
        calls++;
        if (calls == 1) return _notFound('Supplier not found');
        return _json(_supplierJson());
      },
    );
    await _login(tester, api);
    await _openSupplierDetail(tester);

    expect(find.text('Supplier not found'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Supplier not found'), findsNothing);
    expect(find.text('Products supplied'), findsOneWidget);
  });
}
