import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/session_store.dart';
import 'package:visionstock_mobile/features/catalog/presentation/product_detail_screen.dart';
import 'package:visionstock_mobile/features/catalog/presentation/product_edit_screen.dart';
import 'package:visionstock_mobile/main.dart';

const _store = {
  'id': 's1',
  'name': 'Downtown',
  'timezone': 'UTC',
  'currency': 'USD',
};

const _user = {
  'id': 'u1',
  'email': 'owner@test.dev',
  'name': 'Owner',
  'status': 'active',
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

http.Response _notFound() => _json({
  'detail': {'code': 'NOT_FOUND', 'message': 'Not found'},
}, 404);

http.Response _serverError(String message) => _json({
  'detail': {'code': 'HTTP_500', 'message': message},
}, 500);

Map<String, dynamic> _loginPayload(List<String> permissions) => {
  'access_token': 'a-token',
  'refresh_token': 'r-token',
  'expires_in': 900,
  'user': _user,
  'permissions': permissions,
  'stores': [_store],
};

Map<String, dynamic> _mePayload(List<String> permissions) => {
  'user': _user,
  'permissions': permissions,
  'stores': [_store],
};

Map<String, dynamic> _productJson({
  String id = 'p1',
  String name = 'Cola 330ml',
  String barcode = '9780201379624',
}) => {
  'id': id,
  'store_id': 's1',
  'category_id': null,
  'category_name': null,
  'sku': 'SKU-1',
  'barcode': barcode,
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

/// Mock backend for the Scan tab. Serves the barcode lookup, product detail,
/// suppliers and categories; records every barcode lookup request.
class _FakeApi {
  _FakeApi({required this.permissions, this.product, this.lookupError});

  final List<String> permissions;

  /// Product served for `/products/lookup/barcode/*` and `/products/{id}`.
  /// When null, the lookup returns 404 (product not found).
  final Map<String, dynamic>? product;

  /// When set, the barcode lookup returns a 500 with this message.
  final String? lookupError;

  final lookupRequests = <String>[];

  late final ApiClient client = ApiClient(
    baseUrl: 'http://test',
    client: MockClient(_handle),
  );

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;

    if (path == '/auth/login') return _json(_loginPayload(permissions));
    if (path == '/auth/me') return _json(_mePayload(permissions));

    final lookupMatch = RegExp(
      r'^/products/lookup/barcode/(.+)$',
    ).firstMatch(path);
    if (lookupMatch != null && request.method == 'GET') {
      lookupRequests.add(lookupMatch.group(1)!);
      if (lookupError != null) return _serverError(lookupError!);
      if (product == null) return _notFound();
      return _json(product!);
    }

    if (path == '/categories' && request.method == 'GET') {
      return _json(const <Object>[]);
    }

    final suppliersMatch = RegExp(
      r'^/products/([^/]+)/suppliers$',
    ).firstMatch(path);
    if (suppliersMatch != null && request.method == 'GET') {
      return _json(const <Object>[]);
    }

    final detailMatch = RegExp(r'^/products/([^/]+)$').firstMatch(path);
    if (detailMatch != null && request.method == 'GET') {
      if (product == null) return _notFound();
      return _json(product!);
    }

    return _notFound();
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

Future<void> _openScanTab(WidgetTester tester) async {
  await tester.tap(find.text('Scan'));
  await tester.pumpAndSettle();
}

/// Opens the manual entry sheet, enters [value] (empty keeps the field blank)
/// and submits it.
Future<void> _enterBarcode(WidgetTester tester, String value) async {
  await tester.tap(find.text('Enter barcode'));
  await tester.pumpAndSettle();
  if (value.isNotEmpty) {
    await tester.enterText(find.widgetWithText(TextField, 'Barcode'), value);
  }
  await tester.tap(find.text('Look up'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('valid barcode navigates to the product detail', (tester) async {
    final api = _FakeApi(
      permissions: const ['products.view'],
      product: _productJson(),
    );
    await _login(tester, api.client);
    await _openScanTab(tester);

    await _enterBarcode(tester, '9780201379624');

    expect(api.lookupRequests, ['9780201379624']);
    expect(find.byType(ProductDetailScreen), findsOneWidget);
    expect(find.text('Cola 330ml'), findsOneWidget);
  });

  testWidgets('unknown barcode shows the not-found message', (tester) async {
    final api = _FakeApi(permissions: const ['products.view']);
    await _login(tester, api.client);
    await _openScanTab(tester);

    await _enterBarcode(tester, '9780201379624');

    expect(api.lookupRequests, ['9780201379624']);
    expect(find.textContaining('No product found for barcode'), findsOneWidget);
    expect(find.byType(ProductDetailScreen), findsNothing);
  });

  testWidgets(
    'not found with products.manage offers Add that preserves the barcode',
    (tester) async {
      final api = _FakeApi(
        permissions: const ['products.view', 'products.manage'],
      );
      await _login(tester, api.client);
      await _openScanTab(tester);

      await _enterBarcode(tester, '9780201379624');

      expect(
        find.textContaining('No product found for barcode'),
        findsOneWidget,
      );
      expect(find.widgetWithText(SnackBarAction, 'Add'), findsOneWidget);

      await tester.tap(find.widgetWithText(SnackBarAction, 'Add'));
      await tester.pumpAndSettle();

      expect(find.byType(ProductEditScreen), findsOneWidget);
      expect(find.text('New Product'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Barcode'),
      );
      expect(field.controller!.text, '9780201379624');
    },
  );

  testWidgets('not found without products.manage hides the Add action', (
    tester,
  ) async {
    final api = _FakeApi(permissions: const ['products.view']);
    await _login(tester, api.client);
    await _openScanTab(tester);

    await _enterBarcode(tester, '9780201379624');

    expect(find.textContaining('No product found for barcode'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, 'Add'), findsNothing);
  });

  testWidgets('server error surfaces a friendly message', (tester) async {
    final api = _FakeApi(
      permissions: const ['products.view'],
      lookupError: 'Request failed (500)',
    );
    await _login(tester, api.client);
    await _openScanTab(tester);

    await _enterBarcode(tester, '9780201379624');

    expect(api.lookupRequests, ['9780201379624']);
    expect(find.text('Request failed (500)'), findsOneWidget);
    expect(find.textContaining('No product found'), findsNothing);
  });

  testWidgets(
    'invalid barcode shows the validation message and does not lookup',
    (tester) async {
      final api = _FakeApi(permissions: const ['products.view']);
      await _login(tester, api.client);
      await _openScanTab(tester);

      await _enterBarcode(tester, '123');

      expect(
        find.text('Enter at least 6 letters/digits (no spaces or symbols).'),
        findsOneWidget,
      );
      expect(api.lookupRequests, isEmpty);
    },
  );

  testWidgets(
    'empty submission shows the validation message and sends no request',
    (tester) async {
      final api = _FakeApi(permissions: const ['products.view']);
      await _login(tester, api.client);
      await _openScanTab(tester);

      await _enterBarcode(tester, '');

      expect(
        find.text('Enter at least 6 letters/digits (no spaces or symbols).'),
        findsOneWidget,
      );
      expect(api.lookupRequests, isEmpty);
    },
  );
}
