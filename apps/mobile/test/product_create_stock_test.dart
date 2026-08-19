import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/session_store.dart';
import 'package:visionstock_mobile/main.dart';

// products.manage alone gates the Products tab FAB (and no other tab renders a
// FAB), so the default FloatingActionButton Hero tag cannot collide while the
// edit/create route transition runs.
const _permissions = ['products.view', 'products.manage'];

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
  String id = 'p-new',
  String name = 'Widget',
  String? barcode,
}) => {
  'id': id,
  'store_id': 's1',
  'category_id': null,
  'category_name': null,
  'sku': 'SKU-9',
  'barcode': barcode,
  'name': name,
  'description': null,
  'unit': 'pcs',
  'cost_price': 0.0,
  'selling_price': 10.0,
  'reorder_point': 0,
  'reorder_quantity': 0,
  'expiry_tracking_enabled': false,
  'image_url': null,
  'status': 'active',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
};

Map<String, dynamic> _stockJson({
  String id = 'p-new',
  String name = 'Widget',
  String quantity = '0.000',
  bool hasOpening = true,
}) => {
  'product_id': id,
  'product_name': name,
  'sku': 'SKU-9',
  'barcode': null,
  'unit': 'pcs',
  'category_id': null,
  'category_name': null,
  'cost_price': '0.00',
  'selling_price': '10.00',
  'reorder_point': '0.000',
  'reorder_quantity': '0.000',
  'expiry_tracking_enabled': false,
  'quantity': quantity,
  'reserved_quantity': '0.000',
  'available_quantity': quantity,
  'stock_status': hasOpening ? 'healthy' : 'out_of_stock',
  'value': '0.00',
  'has_opening': hasOpening,
  'nearest_expiry_date': null,
  'nearest_expiry_status': null,
  'updated_at': '2026-01-01T00:00:00Z',
  'shelves': <Object>[],
  'expiry_batches': <Object>[],
  'recent_movements': <Object>[],
};

http.Response _serverError(String message) => _json({
  'detail': {'code': 'HTTP_500', 'message': message},
}, 500);

/// Mock backend that records product-create and opening-stock calls.
///
/// [createError] makes POST /products fail; [openingFailures] makes the first
/// N opening-stock calls fail. [withProduct] seeds the product list (used by
/// the update-flow test).
class _FakeApi {
  _FakeApi({
    this.withProduct = false,
    this.productBarcode,
    this.createError,
    this.openingFailures = 0,
  }) {
    remainingOpeningFailures = openingFailures;
  }

  final bool withProduct;
  final String? productBarcode;
  final String? createError;
  final int openingFailures;

  var createCalls = 0;
  var patchCalls = 0;
  final patchBodies = <Map<String, dynamic>>[];
  final openingBodies = <Map<String, dynamic>>[];
  var remainingOpeningFailures = 0;

  late final ApiClient client = ApiClient(
    baseUrl: 'http://test',
    client: MockClient(_handle),
  );

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;

    if (path == '/auth/login') return _json(_loginPayload);
    if (path == '/auth/me') return _json(_mePayload);

    if (path == '/products') {
      if (request.method == 'POST') {
        createCalls += 1;
        if (createError != null) return _serverError(createError!);
        return _json(_productJson());
      }
      return _json(
        _page(
          withProduct
              ? [
                  _productJson(
                    id: 'p1',
                    name: 'Cola 330ml',
                    barcode: productBarcode,
                  ),
                ]
              : [],
        ),
      );
    }

    if (path == '/products/p1/suppliers') return _json(const <Object>[]);

    if (path == '/products/p1' && request.method == 'PATCH') {
      patchCalls += 1;
      patchBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return _json(
        _productJson(id: 'p1', name: 'Cola 330ml', barcode: productBarcode),
      );
    }

    final productDetailMatch = RegExp(r'^/products/([^/]+)$').firstMatch(path);
    if (productDetailMatch != null && request.method == 'GET') {
      return _json(
        _productJson(
          id: productDetailMatch.group(1)!,
          name: 'Cola 330ml',
          barcode: productBarcode,
        ),
      );
    }

    if (path.endsWith('/opening') && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      openingBodies.add(body);
      if (remainingOpeningFailures > 0) {
        remainingOpeningFailures -= 1;
        return _serverError('Request failed (500)');
      }
      final quantity = (body['quantity'] as num).toDouble();
      return _json(_stockJson(quantity: quantity.toStringAsFixed(3)));
    }

    return http.Response(
      '{"detail": {"code": "NOT_FOUND", "message": "Not found"}}',
      404,
    );
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

Future<void> _openCreateForm(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Add product'));
  await tester.pumpAndSettle();
}

Future<void> _fillRequiredFields(WidgetTester tester) async {
  await tester.enterText(find.widgetWithText(TextField, 'Name *'), 'Widget');
  await tester.enterText(find.widgetWithText(TextField, 'SKU *'), 'SKU-9');
  await tester.enterText(find.widgetWithText(TextField, 'Unit *'), 'pcs');
  await tester.enterText(
    find.widgetWithText(TextField, 'Selling price *'),
    '10',
  );
}

Future<void> _submitCreate(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Create product'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Create product'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('create with initial quantity 0 does not call opening stock', (
    tester,
  ) async {
    final api = _FakeApi();
    await _login(tester, api.client);
    await _openCreateForm(tester);
    await _fillRequiredFields(tester);

    // Field defaults to 0; no opening-stock request should be made.
    await _submitCreate(tester);

    expect(find.text('Product created'), findsOneWidget);
    expect(api.createCalls, 1);
    expect(api.openingBodies, isEmpty);
  });

  testWidgets(
    'create with initial quantity opens stock after the product exists',
    (tester) async {
      final api = _FakeApi();
      await _login(tester, api.client);
      await _openCreateForm(tester);
      await _fillRequiredFields(tester);

      await tester.enterText(
        find.widgetWithText(TextField, 'Initial quantity'),
        '5',
      );
      await _submitCreate(tester);

      expect(find.text('Product created'), findsOneWidget);
      expect(api.createCalls, 1);
      expect(api.openingBodies, hasLength(1));
    },
  );

  testWidgets('opening stock uses the created product id and exact quantity', (
    tester,
  ) async {
    final api = _FakeApi();
    await _login(tester, api.client);
    await _openCreateForm(tester);
    await _fillRequiredFields(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Initial quantity'),
      '3.5',
    );
    await _submitCreate(tester);

    expect(find.text('Product created'), findsOneWidget);
    expect(api.openingBodies, hasLength(1));
    expect(api.openingBodies.single['quantity'], 3.5);
  });

  testWidgets('create with batch metadata threads batch code and expiry date', (
    tester,
  ) async {
    final api = _FakeApi();
    await _login(tester, api.client);
    await _openCreateForm(tester);
    await _fillRequiredFields(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Initial quantity'),
      '5',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Batch code (optional)'),
      'LOT-2026-001',
    );
    await tester.ensureVisible(find.text('Pick date'));
    await tester.tap(find.text('Pick date'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await _submitCreate(tester);

    expect(find.text('Product created'), findsOneWidget);
    expect(api.openingBodies, hasLength(1));
    final body = api.openingBodies.single;
    expect(body['quantity'], 5.0);
    expect(body['batch_code'], 'LOT-2026-001');
    expect(body['expiry_date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
  });

  testWidgets('create without batch metadata omits the batch fields', (
    tester,
  ) async {
    final api = _FakeApi();
    await _login(tester, api.client);
    await _openCreateForm(tester);
    await _fillRequiredFields(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Initial quantity'),
      '5',
    );
    await _submitCreate(tester);

    expect(find.text('Product created'), findsOneWidget);
    expect(api.openingBodies, hasLength(1));
    final body = api.openingBodies.single;
    expect(body.containsKey('batch_code'), isFalse);
    expect(body.containsKey('expiry_date'), isFalse);
  });

  testWidgets('batch metadata without initial quantity is never sent', (
    tester,
  ) async {
    final api = _FakeApi();
    await _login(tester, api.client);
    await _openCreateForm(tester);
    await _fillRequiredFields(tester);

    // Initial quantity stays 0; metadata alone must not trigger opening stock.
    await tester.enterText(
      find.widgetWithText(TextField, 'Batch code (optional)'),
      'LOT-2026-001',
    );
    await tester.ensureVisible(find.text('Pick date'));
    await tester.tap(find.text('Pick date'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await _submitCreate(tester);

    expect(find.text('Product created'), findsOneWidget);
    expect(api.createCalls, 1);
    expect(api.openingBodies, isEmpty);
  });

  testWidgets('product creation failure never calls opening stock', (
    tester,
  ) async {
    final api = _FakeApi(createError: 'Request failed (500)');
    await _login(tester, api.client);
    await _openCreateForm(tester);
    await _fillRequiredFields(tester);

    await _submitCreate(tester);

    expect(find.text('New Product'), findsOneWidget); // still on the form
    expect(find.text('Request failed (500)'), findsOneWidget);
    expect(api.createCalls, 1);
    expect(api.openingBodies, isEmpty);
  });

  testWidgets(
    'opening failure surfaces partial success and retry avoids duplicate',
    (tester) async {
      final api = _FakeApi(openingFailures: 1);
      await _login(tester, api.client);
      await _openCreateForm(tester);
      await _fillRequiredFields(tester);

      await tester.enterText(
        find.widgetWithText(TextField, 'Initial quantity'),
        '7',
      );
      await _submitCreate(tester);

      // Product was created, stock failed: stay on form, no success snackbar.
      expect(find.text('Product created'), findsNothing);
      expect(find.text('Stock not applied'), findsOneWidget);
      expect(find.text('Retry opening stock'), findsOneWidget);
      expect(api.createCalls, 1);
      expect(api.openingBodies, hasLength(1));

      // Retry applies stock without creating a duplicate product.
      await tester.ensureVisible(find.text('Retry opening stock'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry opening stock'));
      await tester.pumpAndSettle();

      expect(find.text('Product created'), findsOneWidget);
      expect(api.createCalls, 1);
      expect(api.openingBodies, hasLength(2));
    },
  );

  testWidgets('negative initial quantity is rejected before submission', (
    tester,
  ) async {
    final api = _FakeApi();
    await _login(tester, api.client);
    await _openCreateForm(tester);
    await _fillRequiredFields(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Initial quantity'),
      '-5',
    );
    await _submitCreate(tester);

    // Scroll back to the field so its validation error is built and visible.
    await tester.dragUntilVisible(
      find.widgetWithText(TextField, 'Initial quantity'),
      find.byType(ListView),
      const Offset(0, 200),
    );
    expect(find.text('New Product'), findsOneWidget); // still on the form
    expect(find.text('Must be zero or more'), findsOneWidget);
    expect(api.createCalls, 0);
    expect(api.openingBodies, isEmpty);
  });

  testWidgets(
    'edit mode hides initial quantity and never calls opening stock',
    (tester) async {
      final api = _FakeApi(withProduct: true);
      await _login(tester, api.client);

      await tester.tap(find.text('Cola 330ml'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();

      // Edit mode shows no initial-quantity field.
      expect(find.widgetWithText(TextField, 'Initial quantity'), findsNothing);
      expect(find.text('New Product'), findsNothing);
      expect(find.text('Edit Product'), findsOneWidget);

      await tester.ensureVisible(find.text('Save changes'));
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();

      expect(find.text('Product updated'), findsOneWidget);
      expect(api.patchCalls, 1);
      expect(api.openingBodies, isEmpty);
    },
  );

  testWidgets('edit mode clearing an existing barcode sends barcode: null', (
    tester,
  ) async {
    final api = _FakeApi(withProduct: true, productBarcode: '2100000000123');
    await _login(tester, api.client);

    await tester.tap(find.text('Cola 330ml'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();

    // The barcode is pre-filled from the existing product.
    expect(find.widgetWithText(TextField, 'Barcode'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Barcode'))
          .controller!
          .text,
      '2100000000123',
    );

    // Clear the field and save: PATCH must send an explicit null.
    await tester.enterText(find.widgetWithText(TextField, 'Barcode'), '');
    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(find.text('Product updated'), findsOneWidget);
    expect(api.patchCalls, 1);
    expect(api.patchBodies.single.containsKey('barcode'), isTrue);
    expect(api.patchBodies.single['barcode'], isNull);
    expect(api.openingBodies, isEmpty);
  });
}
