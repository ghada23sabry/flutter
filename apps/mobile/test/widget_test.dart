import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/session_store.dart';
import 'package:visionstock_mobile/main.dart';

http.Client _okClient() => MockClient((request) async {
      return http.Response(
        jsonEncode({
          'access_token': 'a-token',
          'refresh_token': 'r-token',
          'expires_in': 900,
          'user': {'id': 'u1', 'email': 'owner@test.dev', 'name': 'Owner', 'status': 'active'},
          'permissions': ['sales.create'],
          'stores': [
            {'id': 's1', 'name': 'Downtown', 'timezone': 'UTC', 'currency': 'USD'},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

void main() {
  testWidgets('app starts on login screen when no session is stored', (tester) async {
    final apiClient = ApiClient(baseUrl: 'http://test', client: _okClient());
    await tester.pumpWidget(VisionStockApp(apiClient: apiClient, storage: MemorySessionStorage()));
    await tester.pumpAndSettle();

    expect(find.text('VisionStock AI'), findsWidgets);
    expect(find.text('Sign in'), findsOneWidget);
  });
}
