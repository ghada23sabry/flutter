import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/cache.dart';
import 'package:visionstock_mobile/core/session_store.dart';
import 'package:visionstock_mobile/main.dart';

// Permission sets. Keep exactly one FAB-owning permission set per test so the
// default FloatingActionButton Hero tag cannot collide across the
// IndexedStack tabs while an edit/create route transition runs.
const _viewOnly = ['categories.view'];
const _manage = ['categories.view', 'categories.manage'];
const _productManage = ['products.view', 'products.manage', 'categories.view'];
const _noCategories = ['products.view'];

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

http.Response _serverError(String message) => _json({
  'detail': {'code': 'HTTP_500', 'message': message},
}, 500);

Map<String, dynamic> _categoryJson({
  String id = 'c1',
  String? parentId,
  String name = 'Dairy',
  String? code = 'DAIRY',
  String status = 'active',
}) => {
  'id': id,
  'store_id': 's1',
  'parent_id': parentId,
  'name': name,
  'code': code,
  'status': status,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
};

Map<String, dynamic> _productJson({String? categoryId, String? categoryName}) =>
    {
      'id': 'p1',
      'store_id': 's1',
      'category_id': categoryId,
      'category_name': categoryName,
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

/// Stateful mock backend for category + product flows.
class _Backend {
  _Backend({
    required this.permissions,
    List<Map<String, dynamic>>? categories,
    this.productWithCategory = false,
    this.listFailures = 0,
  }) : categories = List.of(categories ?? []) {
    remainingListFailures = listFailures;
  }

  final List<String> permissions;
  final List<Map<String, dynamic>> categories;
  final bool productWithCategory;
  final int listFailures;
  var remainingListFailures = 0;

  var createCalls = 0;
  var categoryListCalls = 0;
  var productPatchCalls = 0;
  final createBodies = <Map<String, dynamic>>[];
  final patchBodies = <Map<String, dynamic>>[];
  final productPatchBodies = <Map<String, dynamic>>[];

  late final ApiClient client = ApiClient(
    baseUrl: 'http://test',
    client: MockClient(_handle),
  );

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;

    if (path == '/auth/login') return _json(_loginPayload(permissions));
    if (path == '/auth/me') return _json(_mePayload(permissions));

    if (path == '/categories') {
      if (request.method == 'POST') {
        createCalls += 1;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        createBodies.add(body);
        final created = _categoryJson(
          id: 'c-new',
          name: body['name'] as String,
          code: body['code'] as String?,
          parentId: body['parent_id'] as String?,
        );
        categories.add(created);
        return _json(created);
      }
      categoryListCalls += 1;
      if (remainingListFailures > 0) {
        remainingListFailures -= 1;
        return _serverError('Request failed (500)');
      }
      final status = request.url.queryParameters['status'];
      final filtered = status == null
          ? List.of(categories)
          : [
              for (final c in categories)
                if (c['status'] == status) c,
            ];
      return _json(filtered);
    }

    final categoryMatch = RegExp(r'^/categories/([^/]+)$').firstMatch(path);
    if (categoryMatch != null) {
      if (request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        patchBodies.add(body);
        final id = categoryMatch.group(1)!;
        final updated = _categoryJson(
          id: id,
          name: body['name'] as String? ?? 'Dairy',
          code: body['code'] as String?,
          parentId: body['parent_id'] as String?,
          status: body['status'] as String? ?? 'active',
        );
        categories
          ..removeWhere((c) => c['id'] == id)
          ..add(updated);
        return _json(updated);
      }
      final id = categoryMatch.group(1)!;
      final match = categories.where((c) => c['id'] == id);
      if (match.isNotEmpty) return _json(match.first);
    }

    if (path == '/products') {
      return _json({
        'items': [
          _productJson(
            categoryId: productWithCategory ? 'c1' : null,
            categoryName: productWithCategory ? 'Dairy' : null,
          ),
        ],
        'total': 1,
        'page': 1,
        'page_size': 30,
        'pages': 1,
      });
    }
    if (path == '/products/p1/suppliers') return _json(const <Object>[]);
    final productMatch = RegExp(r'^/products/([^/]+)$').firstMatch(path);
    if (productMatch != null && request.method == 'PATCH') {
      productPatchCalls += 1;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      productPatchBodies.add(body);
      return _json(
        _productJson(
          categoryId: body['category_id'] as String?,
          categoryName: body['category_id'] == null ? null : 'Dairy',
        ),
      );
    }
    if (productMatch != null && request.method == 'GET') {
      return _json(
        _productJson(
          categoryId: productWithCategory ? 'c1' : null,
          categoryName: productWithCategory ? 'Dairy' : null,
        ),
      );
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

void main() {
  setUp(() => AppCache.instance.clear());

  testWidgets('category list shows active categories with name and code', (
    tester,
  ) async {
    final backend = _Backend(
      permissions: _viewOnly,
      categories: [
        _categoryJson(id: 'c1', name: 'Dairy', code: 'DAIRY'),
        _categoryJson(
          id: 'c2',
          name: 'Frozen',
          code: 'FROZEN',
          status: 'inactive',
        ),
      ],
    );
    await _login(tester, backend.client);

    expect(find.text('Categories'), findsWidgets); // tab + AppBar title
    expect(find.text('Dairy'), findsOneWidget);
    expect(find.text('DAIRY'), findsOneWidget);
    expect(find.text('Frozen'), findsNothing); // inactive hidden by default

    await tester.tap(find.text('Show inactive'));
    await tester.pumpAndSettle();

    expect(find.text('Frozen'), findsOneWidget);
    expect(find.text('Inactive'), findsOneWidget);
  });

  testWidgets('category list empty state offers add action when permitted', (
    tester,
  ) async {
    final backend = _Backend(permissions: _manage);
    await _login(tester, backend.client);

    expect(find.text('No categories found'), findsOneWidget);
    expect(
      find.text('Add your first category to organize products.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Add category'), findsOneWidget);
  });

  testWidgets('category list error shows message and retry', (tester) async {
    final backend = _Backend(
      permissions: _viewOnly,
      categories: [_categoryJson()],
      listFailures: 1,
    );
    await _login(tester, backend.client);

    expect(find.text('Request failed (500)'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Dairy'), findsNothing);
  });

  testWidgets('category list retry recovers after a failed load', (
    tester,
  ) async {
    final backend = _Backend(
      permissions: _viewOnly,
      categories: [_categoryJson()],
      listFailures: 1,
    );
    await _login(tester, backend.client);

    expect(find.text('Request failed (500)'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Request failed (500)'), findsNothing);
    expect(find.text('Dairy'), findsOneWidget);
  });

  testWidgets('create category validation rejects blank name and long code', (
    tester,
  ) async {
    final backend = _Backend(permissions: _manage);
    await _login(tester, backend.client);

    await tester.tap(find.byTooltip('Add category'));
    await tester.pumpAndSettle();
    expect(find.text('New Category'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Code'), 'X' * 41);
    await tester.ensureVisible(find.text('Create category'));
    await tester.tap(find.text('Create category'));
    await tester.pumpAndSettle();

    expect(find.text('This field is required'), findsOneWidget);
    expect(find.text('Must be 40 characters or fewer'), findsOneWidget);
    expect(backend.createCalls, 0);
  });

  testWidgets('create category success posts payload and refreshes the list', (
    tester,
  ) async {
    final backend = _Backend(permissions: _manage);
    await _login(tester, backend.client);

    await tester.tap(find.byTooltip('Add category'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name *'), 'Bakery');
    await tester.enterText(find.widgetWithText(TextField, 'Code'), 'BAKERY');
    await tester.ensureVisible(find.text('Create category'));
    await tester.tap(find.text('Create category'));
    await tester.pumpAndSettle();

    expect(find.text('Category created'), findsOneWidget);
    expect(backend.createCalls, 1);
    final body = backend.createBodies.single;
    expect(body['name'], 'Bakery');
    expect(body['code'], 'BAKERY');
    expect(body.containsKey('status'), isFalse);
    expect(body.containsKey('parent_id'), isFalse);
    expect(find.text('Bakery'), findsOneWidget);
  });

  testWidgets('edit category success persists changes', (tester) async {
    final backend = _Backend(
      permissions: _manage,
      categories: [_categoryJson()],
    );
    await _login(tester, backend.client);

    await tester.tap(find.text('Dairy'));
    await tester.pumpAndSettle();
    expect(find.text('Edit Category'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Name *'),
      'Dairy Products',
    );
    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(find.text('Category updated'), findsOneWidget);
    final body = backend.patchBodies.single;
    expect(body['name'], 'Dairy Products');
    expect(body['status'], 'active');
    expect(find.text('Dairy Products'), findsOneWidget);
  });

  testWidgets('deactivate category sends status inactive', (tester) async {
    final backend = _Backend(
      permissions: _manage,
      categories: [_categoryJson()],
    );
    await _login(tester, backend.client);

    await tester.tap(find.text('Dairy'));
    await tester.pumpAndSettle();
    expect(find.text('Edit Category'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(backend.patchBodies.single['status'], 'inactive');
    // The deactivated category leaves the active list view.
    expect(find.text('No categories found'), findsOneWidget);
  });

  testWidgets('permission gating: no Categories tab without categories.view', (
    tester,
  ) async {
    final backend = _Backend(permissions: _noCategories);
    await _login(tester, backend.client);

    expect(find.text('Categories'), findsNothing);
    expect(find.text('Products'), findsWidgets);
  });

  testWidgets(
    'permission gating: categories.view without manage hides the FAB',
    (tester) async {
      final backend = _Backend(
        permissions: _viewOnly,
        categories: [_categoryJson()],
      );
      await _login(tester, backend.client);

      expect(find.text('Dairy'), findsOneWidget);
      expect(find.byTooltip('Add category'), findsNothing);
    },
  );

  testWidgets('product edit category dropdown lists categories from the API', (
    tester,
  ) async {
    final backend = _Backend(
      permissions: _productManage,
      categories: [
        _categoryJson(id: 'c1', name: 'Dairy'),
        _categoryJson(id: 'c2', name: 'Beverages'),
      ],
    );
    await _login(tester, backend.client);

    await tester.tap(find.text('Cola 330ml'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('product-category-field')));
    await tester.pumpAndSettle();

    expect(find.text('Beverages').last, findsOneWidget);
    expect(find.text('Dairy').last, findsOneWidget);

    await tester.tap(find.text('Beverages').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(backend.productPatchBodies.single['category_id'], 'c2');
  });

  testWidgets('product edit clear-category sends an explicit null', (
    tester,
  ) async {
    final backend = _Backend(
      permissions: _productManage,
      productWithCategory: true,
      categories: [_categoryJson(id: 'c1', name: 'Dairy')],
    );
    await _login(tester, backend.client);

    await tester.tap(find.text('Cola 330ml'));
    await tester.pumpAndSettle();
    expect(
      find.text('Dairy'),
      findsOneWidget,
    ); // detail shows assigned category

    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('product-category-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('None').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    final body = backend.productPatchBodies.single;
    expect(
      body.containsKey('category_id'),
      isTrue,
      reason: 'PATCH must send category_id',
    );
    expect(
      body['category_id'],
      isNull,
      reason: 'clearing must send an explicit null',
    );
  });

  testWidgets('product edit inline new category creates and selects it', (
    tester,
  ) async {
    final backend = _Backend(
      permissions: _productManage,
      categories: [_categoryJson(id: 'c1', name: 'Dairy')],
    );
    await _login(tester, backend.client);

    await tester.tap(find.text('Cola 330ml'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('New Category'));
    await tester.tap(find.text('New Category'));
    await tester.pumpAndSettle();
    expect(find.text('New Category'), findsWidgets); // button + screen title

    await tester.enterText(
      find.widgetWithText(TextField, 'Name *').last,
      'Snacks',
    );
    await tester.ensureVisible(find.text('Create category'));
    await tester.tap(find.text('Create category'));
    await tester.pumpAndSettle();

    expect(backend.createCalls, 1);
    expect(backend.createBodies.single['name'], 'Snacks');
    // Back on the product edit form with the new category selected.
    expect(find.text('Edit Product'), findsOneWidget);
    expect(find.text('Snacks'), findsOneWidget);

    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(backend.productPatchBodies.single['category_id'], 'c-new');
  });

  testWidgets('product edit inline new category keeps form open on invalid', (
    tester,
  ) async {
    final backend = _Backend(permissions: _productManage);
    await _login(tester, backend.client);

    await tester.tap(find.text('Cola 330ml'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('New Category'));
    await tester.tap(find.text('New Category'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Create category'));
    await tester.tap(find.text('Create category'));
    await tester.pumpAndSettle();

    expect(find.text('This field is required'), findsOneWidget);
    expect(backend.createCalls, 0);
    // The create form stays open; the product edit was not submitted.
    expect(find.text('New Category'), findsWidgets);
    expect(find.text('Edit Product'), findsNothing);
  });
}
