// M1 final integration check — real Flutter → HTTP → FastAPI → PostgreSQL.
//
// Not part of the default suite. Requires a live backend; run with:
//   flutter test --dart-define=LIVE_API=true \
//                --dart-define=API_BASE_URL=http://127.0.0.1:8000
//                test/live_integration_test.dart
//
// No MockClient is used anywhere in this file — every request is real.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:visionstock_mobile/core/api/auth_api.dart';
import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/config.dart';
import 'package:visionstock_mobile/core/session.dart';
import 'package:visionstock_mobile/core/session_store.dart';
import 'package:visionstock_mobile/features/auth/login_screen.dart';
import 'package:visionstock_mobile/features/home/app_shell.dart';
import 'package:visionstock_mobile/main.dart';

const bool _live = bool.fromEnvironment('LIVE_API', defaultValue: false);

const String _email =
    String.fromEnvironment('TEST_USER_EMAIL', defaultValue: 'owner@acme.com');
const String _password =
    String.fromEnvironment('TEST_USER_PASSWORD', defaultValue: 'Test1234!');

/// Base URL: env override → compile-time dart-define → AppConfig default.
String get _baseUrl => Platform.environment['API_BASE_URL'] ?? AppConfig.apiBaseUrl;

final bool _skip = !_live;

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

/// Real-async pump loop (must run inside `tester.runAsync`).
///
/// Waits real wall-clock time between frames: `tester.pump(duration)` only
/// advances the fake test clock and returns immediately, which never gives a
/// real HTTP response time to arrive. `Future.delayed` here uses the real
/// timer (runAsync forks a real-async zone).
Future<void> _pumpUntil(WidgetTester tester, Finder finder,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder');
}

Future<void> _realLoginViaUi(WidgetTester tester, String password,
    {required Finder done}) async {
  await tester.runAsync(() async {
    await tester.enterText(find.widgetWithText(TextField, 'Email'), _email);
    await tester.enterText(find.widgetWithText(TextField, 'Password'), password);
    await tester.tap(find.text('Sign in'));
    await _pumpUntil(tester, done);
  });
}

void main() {
  setUpAll(() async {
    if (_live) await _waitForBackend();
  });

  testWidgets('real login: Flutter → API → DB → SessionController → AuthGate → Home',
      skip: _skip, (tester) async {
    final apiClient = _createRealApiClient();
    final storage = MemorySessionStorage();
    await tester.pumpWidget(VisionStockApp(apiClient: apiClient, storage: storage));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);

    await _realLoginViaUi(tester, _password, done: find.byType(AppShell));

    expect(find.byType(AppShell), findsOneWidget);
    expect(find.text('Downtown'), findsOneWidget);
    expect(find.text('Products'), findsWidgets);

    expect(await storage.read('auth.access'), isNotNull);
    expect(await storage.read('auth.refresh'), isNotNull);
  });

  test('real /auth/me works with the JWT returned by real login', skip: _skip, () async {
    final apiClient = _createRealApiClient();
    final controller = SessionController(storage: MemorySessionStorage(), api: AuthApi(apiClient));
    await controller.login(email: _email, password: _password);
    expect(controller.isAuthenticated, isTrue);
    expect(controller.current!.accessToken, isNotEmpty);
    expect(controller.current!.permissions, isNotEmpty);

    final me = await apiClient.get('/auth/me');
    expect(me['user']['email'], _email);
    expect(me['user']['status'], 'active');
  });

  testWidgets('real logout: local session cleared, UI returns to login', skip: _skip,
      (tester) async {
    final apiClient = _createRealApiClient();
    final storage = MemorySessionStorage();
    await tester.pumpWidget(VisionStockApp(apiClient: apiClient, storage: storage));
    await tester.pumpAndSettle();
    await _realLoginViaUi(tester, _password, done: find.byType(AppShell));

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Account'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Sign out'));
      await _pumpUntil(tester, find.byType(LoginScreen));
    });

    expect(find.byType(AppShell), findsNothing);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(await storage.read('auth.access'), isNull);
    expect(await storage.read('auth.refresh'), isNull);
  });

  test('real logout revokes the session server-side', skip: _skip, () async {
    final apiClient = _createRealApiClient();
    final controller = SessionController(storage: MemorySessionStorage(), api: AuthApi(apiClient));
    await controller.login(email: _email, password: _password);
    final token = controller.current!.accessToken;

    await controller.logout();
    expect(controller.isAuthenticated, isFalse);

    final probe = _createRealApiClient()..accessToken = token;
    await expectLater(
      probe.get('/auth/me'),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
      ),
    );
  });

  testWidgets('invalid credentials: structured error → user-friendly message, no raw JSON',
      skip: _skip, (tester) async {
    final apiClient = _createRealApiClient();
    await tester.pumpWidget(VisionStockApp(apiClient: apiClient, storage: MemorySessionStorage()));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.enterText(find.widgetWithText(TextField, 'Email'), _email);
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'definitely-wrong');
      await tester.tap(find.text('Sign in'));
      await _pumpUntil(tester, find.text('Invalid email or password'));
    });

    expect(find.text('Invalid email or password'), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);
    expect(find.textContaining('{'), findsNothing);
    expect(find.textContaining('Exception'), findsNothing);
  });

  test('invalid token: typed ApiException (401 UNAUTHORIZED), no crash', skip: _skip, () async {
    final apiClient = _createRealApiClient()..accessToken = 'not-a-real-token';
    await expectLater(
      apiClient.get('/auth/me'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.code, 'code', 'UNAUTHORIZED'),
      ),
    );
  });
}
