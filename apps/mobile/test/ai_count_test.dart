import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:visionstock_mobile/core/api/auth_api.dart';
import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/models/auth_models.dart';
import 'package:visionstock_mobile/core/permissions.dart';
import 'package:visionstock_mobile/core/session.dart';
import 'package:visionstock_mobile/core/session_store.dart';
import 'package:visionstock_mobile/core/theme/app_theme.dart';
import 'package:visionstock_mobile/features/ai/data/ai_api.dart';
import 'package:visionstock_mobile/features/ai/data/ai_models.dart';
import 'package:visionstock_mobile/features/ai/data/mock_scan_image.dart';
import 'package:visionstock_mobile/features/ai/presentation/ai_count_screen.dart';
import 'package:visionstock_mobile/features/catalog/data/catalog_api.dart';
import 'package:visionstock_mobile/features/inventory/data/inventory_api.dart';

const _aiPermissions = [
  'products.view',
  'inventory.view',
  Permissions.aiScan,
  Permissions.aiView,
  Permissions.aiReconcile,
  Permissions.aiConfirm,
];

const _store = {
  'id': 's1',
  'name': 'Downtown',
  'timezone': 'UTC',
  'currency': 'USD',
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _error(int status, String code, String message) => {
  'detail': {'code': code, 'message': message},
};

// ── Backend JSON builders (mirror real schemas) ───────────────────────────

Map<String, dynamic> _zoneJson() => {
  'id': 'z1',
  'store_id': 's1',
  'name': 'Aisle A',
  'code': 'A-1',
  'status': 'active',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
};

Map<String, dynamic> _shelfJson() => {
  'id': 'sh1',
  'store_id': 's1',
  'zone_id': 'z1',
  'zone_name': 'Aisle A',
  'label': 'Shelf 1',
  'code': 'A1',
  'position': 1,
  'status': 'active',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
};

Map<String, dynamic> _sessionJson({
  String id = 'scan-1',
  String operation = 'count',
  String status = 'processing',
  int imageCount = 1,
  String? note,
}) => {
  'id': id,
  'store_id': 's1',
  'operation': operation,
  'shelf_id': 'sh1',
  'status': status,
  'note': note,
  'image_count': imageCount,
  'started_by': 'u1',
  'completed_by': status == 'processing' ? null : 'u1',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:01Z',
  'completed_at': status == 'processing' ? null : '2026-01-01T00:00:01Z',
};

Map<String, dynamic> _detectionJson({
  String id = 'd1',
  String method = 'barcode',
  String? sku = 'SKU-1',
  String? barcode = '1234567890123',
  String? productId = 'p1',
  double? confidence = 0.98,
  String qty = '1.000',
  String status = 'accepted',
}) => {
  'id': id,
  'session_id': 'scan-1',
  'image_key': null,
  'method': method,
  'detected_sku': sku,
  'detected_barcode': barcode,
  'product_id': productId,
  'confidence': confidence?.toString(),
  'quantity_detected': qty,
  'status': status,
  'meta': null,
  'created_by': 'u1',
  'created_at': '2026-01-01T00:00:01Z',
};

Map<String, dynamic> _reconJson({
  String id = 'r1',
  String productId = 'p1',
  String name = 'Cola 330ml',
  String sku = 'SKU-1',
  String detected = '3.000',
  String system = '1.000',
  String variance = '2.000',
  String status = 'needs_review',
}) => {
  'id': id,
  'session_id': 'scan-1',
  'product_id': productId,
  'product_name': name,
  'sku': sku,
  'detected_quantity': detected,
  'system_quantity': system,
  'variance': variance,
  'status': status,
  'resolution': null,
  'confirmed_by': null,
  'confirmed_at': null,
  'created_at': '2026-01-01T00:00:01Z',
  'updated_at': '2026-01-01T00:00:01Z',
};

Map<String, dynamic> _stockJson({
  String barcode = '1234567890123',
  String sku = 'SKU-1',
}) => {
  'product_id': 'p1',
  'product_name': 'Cola 330ml',
  'sku': sku,
  'barcode': barcode,
  'unit': 'pcs',
  'quantity': '10.000',
  'reserved_quantity': '0.000',
  'available_quantity': '10.000',
  'stock_status': 'healthy',
  'value': '8.00',
};

Map<String, dynamic> _stockPage(List<Map<String, dynamic>> items) => {
  'items': items,
  'total': items.length,
  'page': 1,
  'page_size': 30,
  'pages': items.isEmpty ? 0 : 1,
};

// ── Configurable fake backend ─────────────────────────────────────────────

class _AiConfig {
  List<String> permissions = _aiPermissions;
  bool networkDown = false;

  List<Map<String, dynamic>> zones = [_zoneJson()];
  List<Map<String, dynamic>> shelves = [_shelfJson()];

  int createStatus = 201;
  Map<String, dynamic>? createError;
  Map<String, dynamic>? createdSession;

  Map<String, dynamic>? processError;
  Map<String, dynamic>? processedSession;

  Map<String, dynamic>? detectionsError;
  List<Map<String, dynamic>> detections = [_detectionJson()];

  Map<String, dynamic>? reconciliationsError;
  List<Map<String, dynamic>> reconciliations = [_reconJson()];

  Map<String, dynamic>? confirmError;
  Map<String, dynamic>? confirmedSession;

  Map<String, dynamic>? reconciliationUpdateError;
  Map<String, dynamic>? updatedReconciliation;
  Map<String, dynamic>? lastReconciliationUpdate;

  /// When set, the process endpoint awaits this before responding — lets a
  /// test observe the "processing" state mid-flight.
  Completer<void>? processGate;

  final List<String> calls = [];
  Map<String, dynamic>? lastCreateBody;
  List<int>? processBodyBytes;
}

MockClient _mock(_AiConfig config) {
  return MockClient((request) async {
    final path = request.url.path;
    final method = request.method;
    config.calls.add('$method $path');

    if (config.networkDown) throw http.ClientException('Connection failed');

    if (path == '/auth/login') {
      return _json({
        'access_token': 'a-token',
        'refresh_token': 'r-token',
        'expires_in': 900,
        'user': {
          'id': 'u1',
          'email': 'owner@test.dev',
          'name': 'Owner',
          'status': 'active',
        },
        'permissions': config.permissions,
        'stores': [_store],
      });
    }

    if (path == '/inventory/zones') return _json(config.zones);
    if (path == '/inventory/shelves') return _json(config.shelves);
    if (path == '/inventory/stock') {
      return _json(_stockPage([_stockJson()]));
    }

    if (path == '/ai/scans' && method == 'POST') {
      if (config.createError != null) return _json(config.createError!, 403);
      config.lastCreateBody =
          (request.body.isEmpty ? {} : jsonDecode(request.body))
              as Map<String, dynamic>;
      return _json(
        config.createdSession ?? _sessionJson(),
        config.createStatus,
      );
    }

    final process = RegExp(r'^/ai/scans/([^/]+)/process$').firstMatch(path);
    if (process != null && method == 'POST') {
      config.processBodyBytes = request.bodyBytes;
      if (config.processGate != null) await config.processGate!.future;
      if (config.processError != null) return _json(config.processError!, 422);
      return _json(
        config.processedSession ?? _sessionJson(status: 'completed'),
      );
    }

    final detections = RegExp(
      r'^/ai/scans/([^/]+)/detections$',
    ).firstMatch(path);
    if (detections != null) {
      if (config.detectionsError != null) {
        return _json(config.detectionsError!, 404);
      }
      return _json(config.detections);
    }

    final reconciliations = RegExp(
      r'^/ai/scans/([^/]+)/reconciliations$',
    ).firstMatch(path);
    if (reconciliations != null) {
      if (config.reconciliationsError != null) {
        return _json(config.reconciliationsError!, 404);
      }
      return _json(config.reconciliations);
    }

    final reconPatch = RegExp(
      r'^/ai/scans/([^/]+)/reconciliations/([^/]+)$',
    ).firstMatch(path);
    if (reconPatch != null && method == 'PATCH') {
      config.lastReconciliationUpdate =
          (request.body.isEmpty ? {} : jsonDecode(request.body))
              as Map<String, dynamic>;
      if (config.reconciliationUpdateError != null) {
        return _json(config.reconciliationUpdateError!, 409);
      }
      final body = config.lastReconciliationUpdate!;
      final base = config.updatedReconciliation ?? _reconJson();
      if (body['resolution'] == 'ignore') {
        return _json({...base, 'resolution': 'ignore'});
      }
      if (body['detected_quantity'] != null) {
        final detected = double.parse('${body['detected_quantity']}');
        final system = double.parse(base['system_quantity'] as String);
        return _json({
          ...base,
          'resolution': 'apply',
          'detected_quantity': detected.toStringAsFixed(3),
          'variance': (detected - system).toStringAsFixed(3),
        });
      }
      return _json({...base, 'resolution': body['resolution']});
    }

    final confirm = RegExp(r'^/ai/scans/([^/]+)/confirm$').firstMatch(path);
    if (confirm != null && method == 'POST') {
      if (config.confirmError != null) return _json(config.confirmError!, 409);
      return _json(
        config.confirmedSession ?? _sessionJson(status: 'confirmed'),
      );
    }

    return _json(_error(404, 'NOT_FOUND', 'Not found'), 404);
  });
}

class _FakeImageSource implements ScanImageSource {
  const _FakeImageSource();

  @override
  Future<List<ScanImageOption>> listOptions({required StoreInfo store}) async =>
      [
        ScanImageOption(
          id: 'matched',
          label: 'Matched shelf scene',
          description: 'High-confidence counts — resolves to Completed.',
          bytes: encodeMockImage([
            const MockScanItem(
              method: 'barcode',
              detectedBarcode: '1234567890123',
              detectedSku: 'SKU-1',
              confidence: 0.98,
              quantity: 1,
            ),
          ]),
        ),
      ];
}

// ── Test harness ──────────────────────────────────────────────────────────

Future<_AiConfig> _openAiScreen(
  WidgetTester tester, {
  _AiConfig? config,
  List<String>? permissions,
  AiScanOperation? initialOperation,
}) async {
  config ??= _AiConfig();
  if (permissions != null) config.permissions = permissions;

  final apiClient = ApiClient(baseUrl: 'http://test', client: _mock(config));
  final session = SessionController(
    storage: MemorySessionStorage(),
    api: AuthApi(apiClient),
  );
  await session.login(email: 'owner@test.dev', password: 'Passw0rd!');

  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => AiCountScreen(
                    aiApi: AiApi(apiClient),
                    inventoryApi: InventoryApi(apiClient),
                    catalogApi: CatalogApi(apiClient),
                    session: session,
                    imageSource: const _FakeImageSource(),
                    initialOperation: initialOperation,
                  ),
                ),
              ),
              child: const Text('open-ai-count'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open-ai-count'));
  await tester.pumpAndSettle();
  return config;
}

Future<void> _pickZoneShelfImage(WidgetTester tester) async {
  await tester.tap(find.text('Count'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Aisle A'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Shelf 1'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Matched shelf scene'));
}

void main() {
  // ── Byte-contract units ──────────────────────────────────────────────────

  test('AiScanOperation.fromWire maps the backend literals', () {
    expect(AiScanOperation.count.wire, 'count');
    expect(AiScanOperation.receive.wire, 'receive');
    expect(AiScanOperation.sale.wire, 'sale');
    expect(AiScanOperation.fromWire('count'), AiScanOperation.count);
    expect(AiScanOperation.fromWire('receive'), AiScanOperation.receive);
    expect(AiScanOperation.fromWire('sale'), AiScanOperation.sale);
    expect(AiScanOperation.fromWire(null), AiScanOperation.count);
    expect(AiScanOperation.fromWire('unknown'), AiScanOperation.count);
  });

  test('encodeMockImage emits the documented VS-MOCK-1 byte contract', () {
    final bytes = encodeMockImage(const [
      MockScanItem(
        method: 'barcode',
        detectedBarcode: '1234567890123',
        confidence: 0.98,
        quantity: 2,
      ),
    ]);
    final text = utf8.decode(bytes);
    expect(text, startsWith('VS-MOCK-1\n'));
    final payload = jsonDecode(text.split('\n').last) as Map<String, dynamic>;
    final items = payload['items'] as List;
    expect(items, hasLength(1));
    final item = items.single as Map<String, dynamic>;
    expect(item['detected_barcode'], '1234567890123');
    expect(item['confidence'], closeTo(0.98, 0.0001));
    expect(item['quantity'], closeTo(2, 0.0001));
    expect(item.containsKey('quantity_detected'), isFalse);
  });

  testWidgets('MockScanImageSource builds matched scenes from stock', (
    tester,
  ) async {
    final client = ApiClient(
      baseUrl: 'http://test',
      client: MockClient((request) async {
        if (request.url.path == '/inventory/stock') {
          return _json(
            _stockPage([_stockJson(barcode: '1234567890123', sku: 'SKU-1')]),
          );
        }
        return _json(_error(404, 'NOT_FOUND', 'Not found'), 404);
      }),
    );
    const store = StoreInfo(
      id: 's1',
      name: 'Downtown',
      timezone: 'UTC',
      currency: 'USD',
    );
    final source = MockScanImageSource(InventoryApi(client));
    final options = await source.listOptions(store: store);

    expect(options, hasLength(3));
    final matched = options.firstWhere((o) => o.id == 'matched');
    final payload =
        jsonDecode(utf8.decode(matched.bytes).split('\n').last)
            as Map<String, dynamic>;
    final items = payload['items'] as List;
    final first = items.first as Map<String, dynamic>;
    expect(first['detected_barcode'], '1234567890123');
    expect(first['detected_sku'], 'SKU-1');
    expect(first['confidence'], closeTo(0.98, 0.0001));
    expect(first['quantity'], closeTo(1, 0.0001));
  });

  // ── Permission gate ──────────────────────────────────────────────────────

  testWidgets(
    'permission gate: no ai.scan shows a blocked view, not the wizard',
    (tester) async {
      await _openAiScreen(
        tester,
        permissions: ['products.view', 'inventory.view'],
      );
      expect(find.text('No AI scan access'), findsOneWidget);
      expect(find.text('Aisle A'), findsNothing);
    },
  );

  testWidgets(
    'results without ai.view show permission notes, not an empty reconciliation list',
    (tester) async {
      await _openAiScreen(
        tester,
        permissions: ['products.view', 'inventory.view', Permissions.aiScan],
      );
      await _pickZoneShelfImage(tester);
      await tester.pumpAndSettle();

      expect(
        find.text('Results require the ai.view permission.'),
        findsOneWidget,
      );
      expect(
        find.text('Reconciliation results require the ai.view permission.'),
        findsOneWidget,
      );
      expect(find.text('No reconciliation rows.'), findsNothing);
    },
  );

  // ── Wizard steps ─────────────────────────────────────────────────────────

  testWidgets('zone selection lists zones and advances to shelves', (
    tester,
  ) async {
    await _openAiScreen(tester);
    expect(find.text('AI Scan · Choose an operation'), findsOneWidget);

    await tester.tap(find.text('Count'));
    await tester.pumpAndSettle();
    expect(find.text('AI Count · Step 1 of 3'), findsOneWidget);
    expect(find.text('Aisle A'), findsOneWidget);

    await tester.tap(find.text('Aisle A'));
    await tester.pumpAndSettle();
    expect(find.text('AI Count · Step 2 of 3'), findsOneWidget);
    expect(find.text('Shelf 1'), findsOneWidget);
  });

  testWidgets('shelf selection advances to the image step', (tester) async {
    await _openAiScreen(tester);
    await tester.tap(find.text('Count'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aisle A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shelf 1'));
    await tester.pumpAndSettle();

    expect(find.text('AI Count · Step 3 of 3'), findsOneWidget);
    expect(find.text('Matched shelf scene'), findsOneWidget);
    expect(find.byKey(const ValueKey('barcode-scan-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('camera-capture-card')), findsOneWidget);
  });

  // ── Operation chooser ────────────────────────────────────────────────────

  testWidgets('operation chooser lists count, receive and sale', (
    tester,
  ) async {
    await _openAiScreen(tester);
    expect(find.text('AI Scan · Choose an operation'), findsOneWidget);
    expect(find.byKey(const ValueKey('operation-Count')), findsOneWidget);
    expect(find.byKey(const ValueKey('operation-Receive')), findsOneWidget);
    expect(find.byKey(const ValueKey('operation-Sale')), findsOneWidget);
    expect(find.text('Aisle A'), findsNothing);
  });

  testWidgets(
    'receive skips zone/shelf and posts operation receive without a shelf',
    (tester) async {
      final config = await _openAiScreen(tester);
      await tester.tap(find.text('Receive'));
      await tester.pumpAndSettle();

      expect(find.text('AI Receive · Step 2 of 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('barcode-scan-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('camera-capture-card')), findsOneWidget);
      expect(find.text('Aisle A'), findsNothing);

      await tester.tap(find.text('Matched shelf scene'));
      await tester.pumpAndSettle();

      expect(config.lastCreateBody?['operation'], 'receive');
      expect(config.lastCreateBody?['shelf_id'], isNull);
      expect(find.text('Scan Completed'), findsOneWidget);
    },
  );

  testWidgets(
    'sale posts operation sale and confirms with SALE copy and result text',
    (tester) async {
      final config = await _openAiScreen(tester);
      await tester.tap(find.text('Sale'));
      await tester.pumpAndSettle();

      expect(find.text('AI Sale · Step 2 of 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('barcode-scan-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('camera-capture-card')), findsOneWidget);

      await tester.tap(find.text('Matched shelf scene'));
      await tester.pumpAndSettle();

      expect(config.lastCreateBody?['operation'], 'sale');
      expect(config.lastCreateBody?['shelf_id'], isNull);

      await tester.ensureVisible(
        find.byKey(const ValueKey('confirm-counts-button')),
      );
      await tester.tap(find.byKey(const ValueKey('confirm-counts-button')));
      await tester.pumpAndSettle();

      expect(find.text('Confirm scan?'), findsOneWidget);
      expect(find.textContaining('SALE movements'), findsOneWidget);
      expect(find.textContaining('decreasing stock'), findsOneWidget);

      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(find.text('Scan confirmed'), findsOneWidget);
      expect(
        find.text('1 image(s) processed · 1 product(s) updated.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'receive confirm dialog explains PURCHASE movements increasing stock',
    (tester) async {
      await _openAiScreen(tester);
      await tester.tap(find.text('Receive'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Matched shelf scene'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const ValueKey('confirm-counts-button')),
      );
      await tester.tap(find.byKey(const ValueKey('confirm-counts-button')));
      await tester.pumpAndSettle();

      expect(find.textContaining('PURCHASE movements'), findsOneWidget);
      expect(find.textContaining('increasing stock'), findsOneWidget);
    },
  );

  // ── Create + process ─────────────────────────────────────────────────────

  testWidgets(
    'create scan posts /ai/scans with the shelf then processes bytes',
    (tester) async {
      final config = await _openAiScreen(tester);
      await _pickZoneShelfImage(tester);
      await tester.pumpAndSettle();

      expect(config.calls, contains('POST /ai/scans'));
      expect(config.lastCreateBody?['shelf_id'], 'sh1');

      final processCall = config.calls
          .where((c) => c == 'POST /ai/scans/scan-1/process')
          .length;
      expect(processCall, 1);
      expect(
        utf8.decode(config.processBodyBytes!).split('\n').first,
        'VS-MOCK-1',
      );

      expect(find.text('Scan Completed'), findsOneWidget);
    },
  );

  testWidgets(
    'processing state shows an explicit spinner while the image is processed',
    (tester) async {
      final config = await _openAiScreen(tester);
      final gate = Completer<void>();
      config.processGate = gate;
      await _pickZoneShelfImage(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Processing image…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Processing image…'), findsNothing);
      expect(find.text('Scan Completed'), findsOneWidget);
    },
  );

  // ── Results + reconciliation ─────────────────────────────────────────────

  testWidgets(
    'results render detections with method, confidence and quantity',
    (tester) async {
      await _openAiScreen(tester);
      await _pickZoneShelfImage(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining('Barcode'), findsOneWidget);
      expect(find.textContaining('1 unit(s)'), findsOneWidget);
      expect(find.textContaining('98% conf.'), findsOneWidget);
      expect(find.text('Accepted'), findsOneWidget);
    },
  );

  testWidgets('reconciliation renders detected/system/variance rows', (
    tester,
  ) async {
    await _openAiScreen(tester);
    await _pickZoneShelfImage(tester);
    await tester.pumpAndSettle();

    expect(find.text('Reconciliation'), findsOneWidget);
    expect(find.text('Cola 330ml'), findsOneWidget);
    expect(find.text('Detected'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Variance'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('+2'), findsOneWidget);
    expect(find.text('Needs review'), findsWidgets);
  });

  testWidgets('NEEDS_REVIEW scan shows a warning banner and stays confirmable', (
    tester,
  ) async {
    final config = await _openAiScreen(tester);
    config.processedSession = _sessionJson(status: 'needs_review');
    config.detections = [
      _detectionJson(
        barcode: '9990001112223',
        sku: null,
        productId: null,
        confidence: 0.40,
        status: 'needs_review',
      ),
    ];
    config.reconciliations = [
      _reconJson(variance: '-1.000', status: 'needs_review'),
    ];

    await _pickZoneShelfImage(tester);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Some detections need review. Review the reconciliation below before confirming.',
      ),
      findsOneWidget,
    );
    expect(find.text('Confirm counts'), findsOneWidget);
  });

  // ── Confirm permission gate ──────────────────────────────────────────────

  testWidgets(
    'confirm permission gate: no ai.confirm hides the confirm button',
    (tester) async {
      await _openAiScreen(
        tester,
        permissions: [
          'products.view',
          'inventory.view',
          Permissions.aiScan,
          Permissions.aiView,
          Permissions.aiReconcile,
        ],
      );
      await _pickZoneShelfImage(tester);
      await tester.pumpAndSettle();

      expect(find.text('Confirm counts'), findsNothing);
      expect(
        find.text('Confirming counts requires the ai.confirm permission.'),
        findsOneWidget,
      );
    },
  );

  // ── Successful confirmation ──────────────────────────────────────────────

  testWidgets(
    'successful confirmation asks explicitly, posts and returns to inventory',
    (tester) async {
      final config = await _openAiScreen(tester);
      await _pickZoneShelfImage(tester);
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const ValueKey('confirm-counts-button')),
      );
      await tester.tap(find.byKey(const ValueKey('confirm-counts-button')));
      await tester.pumpAndSettle();

      expect(find.text('Confirm scan?'), findsOneWidget);
      expect(find.textContaining('stock COUNT movements'), findsOneWidget);

      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(config.calls, contains('POST /ai/scans/scan-1/confirm'));
      expect(find.text('Scan confirmed'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('done-button')));
      await tester.pumpAndSettle();
      expect(find.text('open-ai-count'), findsOneWidget);
    },
  );

  // ── Error paths ──────────────────────────────────────────────────────────

  testWidgets(
    'duplicate confirmation (409) stays on results and shows the backend message',
    (tester) async {
      final config = await _openAiScreen(tester);
      config.confirmError = _error(
        409,
        'ALREADY_CONFIRMED',
        'Scan session already confirmed',
      );

      await _pickZoneShelfImage(tester);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('confirm-counts-button')),
      );
      await tester.tap(find.byKey(const ValueKey('confirm-counts-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(find.text('Scan session already confirmed'), findsOneWidget);
      expect(find.text('Scan confirmed'), findsNothing);
      expect(
        find.byKey(const ValueKey('confirm-counts-button')),
        findsOneWidget,
      );
    },
  );

  testWidgets('failed scan shows the failed state with retry', (tester) async {
    final config = await _openAiScreen(tester);
    config.processedSession = _sessionJson(status: 'failed');

    await _pickZoneShelfImage(tester);
    await tester.pumpAndSettle();

    expect(find.text('Scan failed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('network error surfaces a friendly message', (tester) async {
    final config = await _openAiScreen(tester);

    await tester.tap(find.text('Count'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aisle A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shelf 1'));
    await tester.pumpAndSettle();

    config.networkDown = true;
    await tester.tap(find.text('Matched shelf scene'));
    await tester.pumpAndSettle();

    expect(find.text('Scan failed'), findsOneWidget);
    expect(
      find.text('Cannot reach the server. Check your connection.'),
      findsOneWidget,
    );
  });

  testWidgets('server 403 surfaces the backend message', (tester) async {
    final config = await _openAiScreen(tester);
    config.createError = _error(
      403,
      'FORBIDDEN',
      'You do not have permission to start a scan',
    );

    await _pickZoneShelfImage(tester);
    await tester.pumpAndSettle();

    expect(find.text('Scan failed'), findsOneWidget);
    expect(
      find.textContaining('You do not have permission to start a scan'),
      findsOneWidget,
    );
  });

  testWidgets('server 404 on results load surfaces the backend message', (
    tester,
  ) async {
    final config = await _openAiScreen(tester);
    config.detectionsError = _error(404, 'NOT_FOUND', 'Scan session not found');

    await _pickZoneShelfImage(tester);
    await tester.pumpAndSettle();

    expect(find.text('Scan failed'), findsOneWidget);
    expect(find.textContaining('Scan session not found'), findsOneWidget);
  });

  // ── Review: override / ignore ────────────────────────────────────────────

  testWidgets(
    'needs_review rows show Override quantity and Ignore when ai.reconcile is present',
    (tester) async {
      await _openAiScreen(tester);
      await _pickZoneShelfImage(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('override-r1')), findsOneWidget);
      expect(find.byKey(const ValueKey('ignore-r1')), findsOneWidget);
      expect(find.text('Override quantity'), findsOneWidget);
      expect(find.text('Ignore'), findsOneWidget);
    },
  );

  testWidgets(
    'override opens the quantity editor prefilled with the detected quantity',
    (tester) async {
      await _openAiScreen(tester);
      await _pickZoneShelfImage(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('override-r1')));
      await tester.pumpAndSettle();

      expect(find.text('Override quantity'), findsWidgets);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('override-quantity-field')),
      );
      expect(field.controller!.text, '3');
    },
  );

  testWidgets(
    'override with a negative quantity is rejected and nothing is sent',
    (tester) async {
      final config = await _openAiScreen(tester);
      await _pickZoneShelfImage(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('override-r1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('override-quantity-field')),
        '-3',
      );
      await tester.tap(find.byKey(const ValueKey('override-save')));
      await tester.pumpAndSettle();

      expect(find.text('Quantity cannot be negative.'), findsOneWidget);
      expect(
        config.calls.where((c) => c.startsWith('PATCH /ai/scans/')).toList(),
        isEmpty,
      );
      expect(find.byKey(const ValueKey('override-save')), findsOneWidget);
    },
  );

  testWidgets(
    'override with a valid quantity posts apply + quantity and marks the row Overridden',
    (tester) async {
      final config = await _openAiScreen(tester);
      await _pickZoneShelfImage(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('override-r1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('override-quantity-field')),
        '12',
      );
      await tester.tap(find.byKey(const ValueKey('override-save')));
      await tester.pumpAndSettle();

      expect(config.lastReconciliationUpdate?['resolution'], 'apply');
      expect(config.lastReconciliationUpdate?['detected_quantity'], 12);
      expect(find.text('Overridden'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('+11'), findsOneWidget);
      expect(find.text('3'), findsNothing);
    },
  );

  testWidgets('cancelling the override editor saves nothing', (tester) async {
    final config = await _openAiScreen(tester);
    await _pickZoneShelfImage(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('override-r1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('override-quantity-field')),
      '9',
    );
    await tester.tap(find.byKey(const ValueKey('override-cancel')));
    await tester.pumpAndSettle();

    expect(
      config.calls.where((c) => c.startsWith('PATCH /ai/scans/')).toList(),
      isEmpty,
    );
    expect(find.byKey(const ValueKey('override-r1')), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets(
    'ignore posts resolution ignore, shows the Ignored badge and hides review controls',
    (tester) async {
      final config = await _openAiScreen(tester);
      await _pickZoneShelfImage(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('ignore-r1')));
      await tester.pumpAndSettle();

      expect(config.lastReconciliationUpdate?['resolution'], 'ignore');
      expect(config.lastReconciliationUpdate?['detected_quantity'], isNull);
      expect(find.text('Ignored'), findsOneWidget);
      expect(find.byKey(const ValueKey('override-r1')), findsNothing);
      expect(find.byKey(const ValueKey('ignore-r1')), findsNothing);
    },
  );

  testWidgets(
    'confirm after ignore shows the ignore in the summary and does not report the row as updated',
    (tester) async {
      await _openAiScreen(tester);
      await _pickZoneShelfImage(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('ignore-r1')));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 ignored'), findsOneWidget);
      expect(find.textContaining('0 product(s) to apply'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const ValueKey('confirm-counts-button')),
      );
      await tester.tap(find.byKey(const ValueKey('confirm-counts-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(find.text('Scan confirmed'), findsOneWidget);
      expect(
        find.text('1 image(s) processed · 0 product(s) updated.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'without ai.reconcile rows stay read-only and confirm stays available',
    (tester) async {
      await _openAiScreen(
        tester,
        permissions: [
          'products.view',
          'inventory.view',
          Permissions.aiScan,
          Permissions.aiView,
          Permissions.aiConfirm,
        ],
      );
      await _pickZoneShelfImage(tester);
      await tester.pumpAndSettle();

      expect(find.text('Cola 330ml'), findsOneWidget);
      expect(find.byKey(const ValueKey('override-r1')), findsNothing);
      expect(find.byKey(const ValueKey('ignore-r1')), findsNothing);
      expect(
        find.text('Reviewing counts requires the ai.reconcile permission.'),
        findsOneWidget,
      );
      expect(find.text('Confirm counts'), findsOneWidget);
    },
  );

  testWidgets(
    'a 409 review update surfaces the backend message and keeps the row reviewable',
    (tester) async {
      final config = await _openAiScreen(tester);
      config.reconciliationUpdateError = _error(
        409,
        'SCAN_NOT_OPEN',
        'Scan session is not open for review',
      );

      await _pickZoneShelfImage(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('ignore-r1')));
      await tester.pumpAndSettle();

      expect(find.text('Scan session is not open for review'), findsOneWidget);
      expect(find.byKey(const ValueKey('ignore-r1')), findsOneWidget);
    },
  );

  // ── initialOperation (direct Sale / Receive entry) ─────────────────────

  testWidgets(
    'initialOperation=sale skips operation chooser and goes straight to image',
    (tester) async {
      await _openAiScreen(tester, initialOperation: AiScanOperation.sale);

      expect(find.text('AI Scan · Choose an operation'), findsNothing);
      expect(find.text('AI Sale · Step 2 of 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('barcode-scan-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('camera-capture-card')), findsOneWidget);
    },
  );

  testWidgets(
    'initialOperation=receive skips operation chooser and goes straight to image',
    (tester) async {
      await _openAiScreen(tester, initialOperation: AiScanOperation.receive);

      expect(find.text('AI Scan · Choose an operation'), findsNothing);
      expect(find.text('AI Receive · Step 2 of 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('barcode-scan-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('camera-capture-card')), findsOneWidget);
    },
  );

  testWidgets(
    'initialOperation=sale back button pops the screen',
    (tester) async {
      await _openAiScreen(tester, initialOperation: AiScanOperation.sale);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      // Screen should have popped back to the launch button.
      expect(find.text('open-ai-count'), findsOneWidget);
    },
  );
}
