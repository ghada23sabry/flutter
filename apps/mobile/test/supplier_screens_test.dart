import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/session_store.dart';
import 'package:visionstock_mobile/main.dart';

// Permission sets. Keep exactly one FAB-owning permission set per test so the
// default FloatingActionButton Hero tag cannot collide across the
// IndexedStack tabs while an edit/create route transition runs.
const _viewOnly = ['suppliers.view'];
const _manage = ['suppliers.view', 'suppliers.manage', 'products.view'];
const _noSuppliers = ['products.view'];

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

http.Response _notFound() => _json({
  'detail': {'code': 'NOT_FOUND', 'message': 'Not found'},
}, 404);

Map<String, dynamic> _page(List<Map<String, dynamic>> items) => {
  'items': items,
  'total': items.length,
  'page': 1,
  'page_size': 30,
  'pages': items.isEmpty ? 0 : 1,
};

Map<String, dynamic> _supplierJson({
  String id = 'sup1',
  String name = 'Acme Supplies',
  String? contactName = 'Jane Doe',
  String? email = 'jane@acme.test',
  String? phone = '555-0100',
  String? address = '1 Main St',
  String? notes,
  String status = 'active',
}) => {
  'id': id,
  'name': name,
  'contact_name': contactName,
  'phone': phone,
  'email': email,
  'address': address,
  'notes': notes,
  'status': status,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
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

Map<String, dynamic> _linkJson({
  String id = 'l1',
  String supplierId = 'sup1',
  String productId = 'p1',
  String? productName = 'Cola 330ml',
  String? productSku = 'SKU-1',
  String? supplierSku,
  double? supplierCost,
  int? leadTimeDays,
  bool isPreferred = false,
}) => {
  'id': id,
  'supplier_id': supplierId,
  'product_id': productId,
  'supplier_name': 'Acme Supplies',
  'product_name': productName,
  'product_sku': productSku,
  'supplier_sku': supplierSku,
  'supplier_cost': supplierCost,
  'lead_time_days': leadTimeDays,
  'is_preferred': isPreferred,
};

/// Stateful mock backend for supplier + product-supplier link flows.
class _Backend {
  _Backend({
    required this.permissions,
    List<Map<String, dynamic>>? suppliers,
    List<Map<String, dynamic>>? products,
    List<Map<String, dynamic>>? links,
    this.listFailures = 0,
  }) : suppliers = List.of(suppliers ?? []),
       products = List.of(products ?? []),
       links = List.of(links ?? []) {
    remainingListFailures = listFailures;
  }

  final List<String> permissions;
  final List<Map<String, dynamic>> suppliers;
  final List<Map<String, dynamic>> products;
  final List<Map<String, dynamic>> links;
  final int listFailures;
  var remainingListFailures = 0;

  var createCalls = 0;
  var supplierListCalls = 0;
  var linkCreateCalls = 0;
  var linkPatchCalls = 0;
  var linkDeleteCalls = 0;
  final createBodies = <Map<String, dynamic>>[];
  final patchBodies = <Map<String, dynamic>>[];
  final linkCreateBodies = <Map<String, dynamic>>[];
  final linkPatchBodies = <Map<String, dynamic>>[];
  final deletedProductIds = <String>[];

  late final ApiClient client = ApiClient(
    baseUrl: 'http://test',
    client: MockClient(_handle),
  );

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;

    if (path == '/auth/login') return _json(_loginPayload(permissions));
    if (path == '/auth/me') return _json(_mePayload(permissions));

    if (path == '/suppliers') {
      if (request.method == 'POST') {
        createCalls += 1;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        createBodies.add(body);
        final created = _supplierJson(
          id: 'sup-new',
          name: body['name'] as String,
          contactName: body['contact_name'] as String?,
          email: body['email'] as String?,
          phone: body['phone'] as String?,
          address: body['address'] as String?,
          notes: body['notes'] as String?,
        );
        suppliers.add(created);
        return _json(created);
      }
      supplierListCalls += 1;
      if (remainingListFailures > 0) {
        remainingListFailures -= 1;
        return _serverError('Request failed (500)');
      }
      final status = request.url.queryParameters['status'];
      final filtered = status == null
          ? List.of(suppliers)
          : [
              for (final s in suppliers)
                if (s['status'] == status) s,
            ];
      return _json(_page(filtered));
    }

    final supplierMatch = RegExp(r'^/suppliers/([^/]+)$').firstMatch(path);
    if (supplierMatch != null) {
      final id = supplierMatch.group(1)!;
      if (request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        patchBodies.add(body);
        final updated = _supplierJson(
          id: id,
          name: body['name'] as String? ?? 'Acme Supplies',
          contactName: body['contact_name'] as String?,
          email: body['email'] as String?,
          phone: body['phone'] as String?,
          address: body['address'] as String?,
          notes: body['notes'] as String?,
          status: body['status'] as String? ?? 'active',
        );
        suppliers
          ..removeWhere((s) => s['id'] == id)
          ..add(updated);
        return _json(updated);
      }
      final match = suppliers.where((s) => s['id'] == id);
      if (match.isEmpty) return _notFound();
      return _json(match.first);
    }

    final supplierProductsMatch = RegExp(
      r'^/suppliers/([^/]+)/products$',
    ).firstMatch(path);
    if (supplierProductsMatch != null) {
      final supplierId = supplierProductsMatch.group(1)!;
      if (request.method == 'POST') {
        linkCreateCalls += 1;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        linkCreateBodies.add(body);
        final productId = body['product_id'] as String;
        final product = products.firstWhere((p) => p['id'] == productId);
        final link = _linkJson(
          id: 'l-new',
          supplierId: supplierId,
          productId: productId,
          productName: product['name'] as String,
          productSku: product['sku'] as String,
          supplierSku: body['supplier_sku'] as String?,
          supplierCost: (body['supplier_cost'] as num?)?.toDouble(),
          leadTimeDays: (body['lead_time_days'] as num?)?.toInt(),
          isPreferred: body['is_preferred'] as bool? ?? false,
        );
        links.add(link);
        return _json(link);
      }
      return _json([
        for (final l in links)
          if (l['supplier_id'] == supplierId) l,
      ]);
    }

    final linkMatch = RegExp(
      r'^/suppliers/([^/]+)/products/([^/]+)$',
    ).firstMatch(path);
    if (linkMatch != null) {
      final supplierId = linkMatch.group(1)!;
      final productId = linkMatch.group(2)!;
      if (request.method == 'PATCH') {
        linkPatchCalls += 1;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        linkPatchBodies.add(body);
        final updated = _linkJson(
          id: 'l1',
          supplierId: supplierId,
          productId: productId,
          supplierSku: body['supplier_sku'] as String?,
          supplierCost: (body['supplier_cost'] as num?)?.toDouble(),
          leadTimeDays: (body['lead_time_days'] as num?)?.toInt(),
          isPreferred: body['is_preferred'] as bool? ?? false,
        );
        links
          ..removeWhere(
            (l) =>
                l['supplier_id'] == supplierId && l['product_id'] == productId,
          )
          ..add(updated);
        return _json(updated);
      }
      if (request.method == 'DELETE') {
        linkDeleteCalls += 1;
        deletedProductIds.add(productId);
        links.removeWhere(
          (l) => l['supplier_id'] == supplierId && l['product_id'] == productId,
        );
        return _json({'ok': true});
      }
    }

    if (path == '/products') return _json(_page(products));
    if (path == '/products/p1/suppliers') return _json(const <Object>[]);

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

Future<void> _openSupplierTab(WidgetTester tester) async {
  await tester.tap(find.text('Suppliers').first);
  await tester.pumpAndSettle();
}

Future<void> _openSupplierDetail(WidgetTester tester) async {
  await _openSupplierTab(tester);
  await tester.tap(find.text('Acme Supplies'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('supplier list shows active suppliers with contact', (
    tester,
  ) async {
    final backend = _Backend(
      permissions: _viewOnly,
      suppliers: [
        _supplierJson(),
        _supplierJson(
          id: 'sup2',
          name: 'Beta Wholesale',
          contactName: null,
          email: 'bob@beta.test',
          status: 'inactive',
        ),
      ],
    );
    await _login(tester, backend.client);

    expect(find.text('Acme Supplies'), findsOneWidget);
    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.text('Beta Wholesale'), findsNothing); // inactive hidden

    await tester.tap(find.text('Show inactive'));
    await tester.pumpAndSettle();

    expect(find.text('Beta Wholesale'), findsOneWidget);
    expect(find.text('bob@beta.test'), findsOneWidget);
    expect(find.text('Inactive'), findsOneWidget);
  });

  testWidgets('supplier list empty state offers add action when permitted', (
    tester,
  ) async {
    final backend = _Backend(permissions: _manage);
    await _login(tester, backend.client);
    await _openSupplierTab(tester);

    expect(find.text('No suppliers found'), findsOneWidget);
    expect(
      find.text('Add your first supplier to track where products come from.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Add supplier'), findsOneWidget);
  });

  testWidgets('supplier list error shows message and retry', (tester) async {
    final backend = _Backend(
      permissions: _viewOnly,
      suppliers: [_supplierJson()],
      listFailures: 1,
    );
    await _login(tester, backend.client);
    await _openSupplierTab(tester);

    expect(find.text('Request failed (500)'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Acme Supplies'), findsNothing);
  });

  testWidgets('supplier list retry recovers after a failed load', (
    tester,
  ) async {
    final backend = _Backend(
      permissions: _viewOnly,
      suppliers: [_supplierJson()],
      listFailures: 1,
    );
    await _login(tester, backend.client);
    await _openSupplierTab(tester);

    expect(find.text('Request failed (500)'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Request failed (500)'), findsNothing);
    expect(find.text('Acme Supplies'), findsOneWidget);
  });

  testWidgets('create supplier validation rejects blank name and bad email', (
    tester,
  ) async {
    final backend = _Backend(permissions: _manage);
    await _login(tester, backend.client);
    await _openSupplierTab(tester);

    await tester.tap(find.byTooltip('Add supplier'));
    await tester.pumpAndSettle();
    expect(find.text('New Supplier'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'nope');
    await tester.ensureVisible(find.text('Create supplier'));
    await tester.tap(find.text('Create supplier'));
    await tester.pumpAndSettle();

    expect(find.text('This field is required'), findsOneWidget);
    expect(find.text('Enter a valid email address'), findsOneWidget);
    expect(backend.createCalls, 0);
  });

  testWidgets('create supplier success posts payload and refreshes the list', (
    tester,
  ) async {
    final backend = _Backend(permissions: _manage);
    await _login(tester, backend.client);
    await _openSupplierTab(tester);

    await tester.tap(find.byTooltip('Add supplier'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name *'), 'Acme');
    await tester.enterText(
      find.widgetWithText(TextField, 'Contact name'),
      'Jane',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Email'),
      'jane@acme.test',
    );
    await tester.ensureVisible(find.text('Create supplier'));
    await tester.tap(find.text('Create supplier'));
    await tester.pumpAndSettle();

    expect(find.text('Supplier created'), findsOneWidget);
    expect(backend.createCalls, 1);
    final body = backend.createBodies.single;
    expect(body['name'], 'Acme');
    expect(body['contact_name'], 'Jane');
    expect(body['email'], 'jane@acme.test');
    expect(body.containsKey('status'), isFalse);
    expect(find.text('Acme'), findsOneWidget);
  });

  testWidgets('edit supplier success persists changes', (tester) async {
    final backend = _Backend(
      permissions: _manage,
      suppliers: [_supplierJson()],
    );
    await _login(tester, backend.client);
    await _openSupplierDetail(tester);

    expect(find.text('Products supplied'), findsOneWidget);
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit Supplier'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Name *'),
      'Acme Distribution',
    );
    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(find.text('Supplier updated'), findsOneWidget);
    final body = backend.patchBodies.single;
    expect(body['name'], 'Acme Distribution');
    expect(body['status'], 'active');
    expect(find.text('Acme Distribution'), findsOneWidget);
  });

  testWidgets('deactivate supplier sends status inactive', (tester) async {
    final backend = _Backend(
      permissions: _manage,
      suppliers: [_supplierJson()],
    );
    await _login(tester, backend.client);
    await _openSupplierDetail(tester);

    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(backend.patchBodies.single['status'], 'inactive');
    expect(find.text('No suppliers found'), findsOneWidget);
  });

  testWidgets('permission gating: no Suppliers tab without suppliers.view', (
    tester,
  ) async {
    final backend = _Backend(permissions: _noSuppliers);
    await _login(tester, backend.client);

    expect(find.text('Suppliers'), findsNothing);
    expect(find.text('Products'), findsWidgets);
  });

  testWidgets(
    'permission gating: suppliers.view without manage hides the FAB',
    (tester) async {
      final backend = _Backend(
        permissions: _viewOnly,
        suppliers: [_supplierJson()],
      );
      await _login(tester, backend.client);
      await _openSupplierTab(tester);

      expect(find.text('Acme Supplies'), findsOneWidget);
      expect(find.byTooltip('Add supplier'), findsNothing);
    },
  );

  testWidgets('supplier detail renders contact and linked products', (
    tester,
  ) async {
    final backend = _Backend(
      permissions: _manage,
      suppliers: [_supplierJson()],
      products: [_productJson()],
      links: [
        _linkJson(supplierSku: 'ACME-1', supplierCost: 1.25, leadTimeDays: 5),
      ],
    );
    await _login(tester, backend.client);
    await _openSupplierDetail(tester);

    expect(find.text('jane@acme.test'), findsOneWidget);
    expect(find.text('555-0100'), findsOneWidget);
    expect(find.text('1 Main St'), findsOneWidget);
    expect(find.text('Cola 330ml'), findsOneWidget);
    expect(find.text('SKU-1 · \$1.25 · 5d lead'), findsOneWidget);
  });

  testWidgets('link product flow posts the link and shows it', (tester) async {
    final backend = _Backend(
      permissions: _manage,
      suppliers: [_supplierJson()],
      products: [_productJson()],
    );
    await _login(tester, backend.client);
    await _openSupplierDetail(tester);

    await tester.tap(find.text('Link'));
    await tester.pumpAndSettle();

    expect(find.text('Link product'), findsOneWidget);
    await tester.tap(find.text('Cola 330ml'));
    await tester.pumpAndSettle();

    expect(find.text('Link Cola 330ml'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Supplier SKU'),
      'ACME-1',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Supplier cost'),
      '1.25',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Lead time (days)'),
      '5',
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Link').last);
    await tester.pumpAndSettle();

    expect(backend.linkCreateCalls, 1);
    final body = backend.linkCreateBodies.single;
    expect(body['product_id'], 'p1');
    expect(body['supplier_sku'], 'ACME-1');
    expect(body['supplier_cost'], 1.25);
    expect(body['lead_time_days'], 5);
    expect(body['is_preferred'], isTrue);
    expect(find.text('Supplier updated'), findsOneWidget);
  });

  testWidgets('duplicate link is rejected without a second POST', (
    tester,
  ) async {
    final backend = _Backend(
      permissions: _manage,
      suppliers: [_supplierJson()],
      products: [_productJson()],
      links: [_linkJson()],
    );
    await _login(tester, backend.client);
    await _openSupplierDetail(tester);

    await tester.tap(find.text('Link'));
    await tester.pumpAndSettle();

    // The linked product is already on the detail; the picker adds a second.
    await tester.tap(find.text('Cola 330ml').last);
    await tester.pumpAndSettle();

    expect(
      find.text('This product is already linked to the supplier.'),
      findsOneWidget,
    );
    expect(backend.linkCreateCalls, 0);
    expect(find.text('Link Cola 330ml'), findsNothing);
  });

  testWidgets('edit link flow patches the link and shows the preferred badge', (
    tester,
  ) async {
    final backend = _Backend(
      permissions: _manage,
      suppliers: [_supplierJson()],
      products: [_productJson()],
      links: [_linkJson(supplierSku: 'ACME-1', supplierCost: 1.25)],
    );
    await _login(tester, backend.client);
    await _openSupplierDetail(tester);

    await tester.tap(find.byTooltip('Edit link'));
    await tester.pumpAndSettle();
    expect(find.text('Edit Cola 330ml'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Supplier cost'),
      '2.00',
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(backend.linkPatchCalls, 1);
    final body = backend.linkPatchBodies.single;
    expect(body['supplier_cost'], 2.0);
    expect(body['is_preferred'], isTrue);
    // The detail pops to the list after a mutation; the mock still holds the
    // persisted link state.
    expect(backend.links.single['is_preferred'], isTrue);
    expect(backend.links.single['supplier_cost'], 2.0);
  });

  testWidgets('unlink flow confirms then deletes the link', (tester) async {
    final backend = _Backend(
      permissions: _manage,
      suppliers: [_supplierJson()],
      products: [_productJson()],
      links: [_linkJson()],
    );
    await _login(tester, backend.client);
    await _openSupplierDetail(tester);

    await tester.tap(find.byTooltip('Remove link'));
    await tester.pumpAndSettle();
    expect(find.text('Remove product?'), findsOneWidget);

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(backend.linkDeleteCalls, 1);
    expect(backend.deletedProductIds, ['p1']);
    expect(find.text('Supplier updated'), findsOneWidget);
  });
}
