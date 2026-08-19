import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:visionstock_mobile/core/api/auth_api.dart';
import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/session.dart';
import 'package:visionstock_mobile/core/session_store.dart';
import 'package:visionstock_mobile/features/auth/login_screen.dart';
import 'package:visionstock_mobile/features/home/app_shell.dart';
import 'package:visionstock_mobile/main.dart';

const _mePayload = {
  'user': {'id': 'u1', 'email': 'owner@test.dev', 'name': 'Owner', 'status': 'active'},
  'permissions': ['products.view', 'products.manage', 'suppliers.view', 'suppliers.manage'],
  'stores': [
    {'id': 's1', 'name': 'Downtown', 'timezone': 'UTC', 'currency': 'USD'},
  ],
};

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

http.Response _json(Object body, int status) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// Mock backend: login/me/logout answered, everything else degrades to `{}`.
http.Client _okClient() => MockClient((request) async {
      switch (request.url.path) {
        case '/auth/login':
          return _json(_loginPayload, 200);
        case '/auth/me':
          return _json(_mePayload, 200);
        case '/auth/logout':
          return http.Response('{}', 200);
        default:
          return http.Response('{}', 200);
      }
    });

/// Seed a persisted session (tokens + cached session fragment).
Future<MemorySessionStorage> _seededStorage() async {
  final storage = MemorySessionStorage();
  await storage.write('auth.access', 'a-token');
  await storage.write('auth.refresh', 'r-token');
  await storage.write('auth.session', jsonEncode(_loginPayload));
  return storage;
}

Widget _host(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('login screen renders email, password and submit', (tester) async {
    final controller = SessionController(
      storage: MemorySessionStorage(),
      api: AuthApi(ApiClient(baseUrl: 'http://test', client: _okClient())),
    );
    await tester.pumpWidget(_host(LoginScreen(controller: controller)));

    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('successful login navigates to home shell', (tester) async {
    final apiClient = ApiClient(baseUrl: 'http://test', client: _okClient());
    await tester.pumpWidget(VisionStockApp(apiClient: apiClient, storage: MemorySessionStorage()));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'owner@test.dev');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'Passw0rd!');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
    expect(find.text('Downtown'), findsOneWidget);
    expect(find.text('Products'), findsWidgets);
  });

  testWidgets('failed login shows backend error message', (tester) async {
    final apiClient = ApiClient(
      baseUrl: 'http://test',
      client: MockClient((request) async {
        return _json(
          {'detail': {'code': 'INVALID_CREDENTIALS', 'message': 'Invalid email or password'}},
          401,
        );
      }),
    );
    await tester.pumpWidget(VisionStockApp(apiClient: apiClient, storage: MemorySessionStorage()));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'owner@test.dev');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'wrong');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Invalid email or password'), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);
  });

  testWidgets('persisted session restores straight to home shell', (tester) async {
    final storage = await _seededStorage();
    final apiClient = ApiClient(baseUrl: 'http://test', client: _okClient());

    await tester.pumpWidget(VisionStockApp(apiClient: apiClient, storage: storage));
    await tester.pumpAndSettle();

    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
    expect(find.text('Downtown'), findsOneWidget);
  });

  testWidgets('sign out returns to login screen', (tester) async {
    final storage = await _seededStorage();
    final apiClient = ApiClient(baseUrl: 'http://test', client: _okClient());

    await tester.pumpWidget(VisionStockApp(apiClient: apiClient, storage: storage));
    await tester.pumpAndSettle();
    expect(find.byType(AppShell), findsOneWidget);

    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);
    expect(await storage.read('auth.access'), isNull);
    expect(await storage.read('auth.refresh'), isNull);
  });
}
