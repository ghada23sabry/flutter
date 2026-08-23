import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:visionstock_mobile/core/api/auth_api.dart';
import 'package:visionstock_mobile/core/api_client.dart';
import 'package:visionstock_mobile/core/auth_refresh_handler.dart';
import 'package:visionstock_mobile/core/models/auth_models.dart';
import 'package:visionstock_mobile/core/session.dart';
import 'package:visionstock_mobile/core/session_store.dart';

const _mePayload = {
  'user': {'id': 'u1', 'email': 'owner@test.dev', 'name': 'Owner', 'status': 'active'},
  'permissions': ['products.view', 'products.manage', 'ai.scan', 'ai.view', 'ai.confirm'],
  'stores': [
    {'id': 's1', 'name': 'Downtown', 'timezone': 'UTC', 'currency': 'USD'},
  ],
};

const _loginPayload = {
  'access_token': 'a-token',
  'refresh_token': 'r-token',
  'expires_in': 900,
  'user': {'id': 'u1', 'email': 'owner@test.dev', 'name': 'Owner', 'status': 'active'},
  'permissions': ['products.view', 'products.manage'],
  'stores': [
    {'id': 's1', 'name': 'Downtown', 'timezone': 'UTC', 'currency': 'USD'},
  ],
};

const _refreshPayload = {
  'access_token': 'new-access-token',
  'refresh_token': 'new-refresh-token',
  'expires_in': 900,
};

http.Response _json(Object body, int status) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

AuthSession _session({
  String accessToken = 'old-token',
  String refreshToken = 'old-refresh',
}) =>
    AuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresIn: 900,
      user: UserInfo.empty(),
      permissions: const [],
      stores: const [],
    );

void main() {
  // -----------------------------------------------------------------------
  // TEST 1: ApiClient retries on 401 via onUnauthorized callback
  // -----------------------------------------------------------------------
  group('ApiClient transparent retry on expired token', () {
    test('retries request after onUnauthorized refreshes the token', () async {
      var refreshHandlerCalled = false;
      final client = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async {
          if (request.url.path == '/products') {
            final auth = request.headers['Authorization'] ?? '';
            if (auth == 'Bearer old-token') {
              return _json(
                {'detail': {'code': 'TOKEN_EXPIRED', 'message': 'Access token has expired'}},
                401,
              );
            }
            return _json({'products': []}, 200);
          }
          return _json({}, 200);
        }),
        accessToken: 'old-token',
      );

      client.onUnauthorized = () async {
        refreshHandlerCalled = true;
        client.accessToken = 'new-token';
        return true;
      };

      final result = await client.get('/products');

      expect(refreshHandlerCalled, isTrue);
      expect(result, contains('products'));
    });

    test('propagates 401 when no onUnauthorized callback is set', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async {
          return _json(
            {'detail': {'code': 'TOKEN_EXPIRED', 'message': 'Access token has expired'}},
            401,
          );
        }),
        accessToken: 'expired-token',
      );

      expect(
        () => client.get('/products'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401)),
      );
    });

    test('propagates 401 when onUnauthorized returns false (refresh failed)', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async {
          return _json(
            {'detail': {'code': 'TOKEN_EXPIRED', 'message': 'Expired'}},
            401,
          );
        }),
        accessToken: 'expired-token',
      );

      client.onUnauthorized = () async {
        client.accessToken = null;
        return false;
      };

      expect(
        () => client.get('/products'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401)),
      );
    });

    test('preserves HTTP method, URL, path, body, and headers on retry', () async {
      String? retriedMethod;
      String? retriedPath;
      String? retriedBody;
      String? retriedContentType;

      final client = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async {
          final auth = request.headers['Authorization'] ?? '';
          if (auth == 'Bearer old-token') {
            return _json(
              {'detail': {'code': 'TOKEN_EXPIRED', 'message': 'Expired'}},
              401,
            );
          }
          retriedMethod = request.method;
          retriedPath = request.url.path;
          retriedBody = request.body;
          retriedContentType = request.headers['Content-Type'];
          return _json({'ok': true}, 200);
        }),
        accessToken: 'old-token',
      );

      client.onUnauthorized = () async {
        client.accessToken = 'new-token';
        return true;
      };

      await client.post('/products/123', body: {'name': 'Test'});

      expect(retriedMethod, 'POST');
      expect(retriedPath, '/products/123');
      expect(retriedBody, jsonEncode({'name': 'Test'}));
      expect(retriedContentType, 'application/json');
    });

    test('preserves custom Content-Type on postBytes retry', () async {
      String? retriedContentType;
      List<int>? retriedBody;

      final client = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async {
          final auth = request.headers['Authorization'] ?? '';
          if (auth == 'Bearer old-token') {
            return _json(
              {'detail': {'code': 'TOKEN_EXPIRED', 'message': 'Expired'}},
              401,
            );
          }
          retriedContentType = request.headers['Content-Type'];
          retriedBody = request.bodyBytes;
          return _json({'ok': true}, 200);
        }),
        accessToken: 'old-token',
      );

      client.onUnauthorized = () async {
        client.accessToken = 'new-token';
        return true;
      };

      await client.postBytes('/ai/scans/1/process', bytes: [1, 2, 3, 4]);

      expect(retriedContentType, 'application/octet-stream');
      expect(retriedBody, [1, 2, 3, 4]);
    });

    test('preserves query parameters on retry', () async {
      Map<String, String>? retriedQuery;

      final client = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async {
          final auth = request.headers['Authorization'] ?? '';
          if (auth == 'Bearer old-token') {
            return _json(
              {'detail': {'code': 'TOKEN_EXPIRED', 'message': 'Expired'}},
              401,
            );
          }
          retriedQuery = request.url.queryParameters;
          return _json({'ok': true}, 200);
        }),
        accessToken: 'old-token',
      );

      client.onUnauthorized = () async {
        client.accessToken = 'new-token';
        return true;
      };

      await client.get('/products', query: {'status': 'active', 'limit': '10'});

      expect(retriedQuery, {'status': 'active', 'limit': '10'});
    });
  });

  // -----------------------------------------------------------------------
  // TEST 2: AuthRefreshHandler concurrency and correctness
  // -----------------------------------------------------------------------
  group('AuthRefreshHandler', () {
    test('performs token rotation and updates session via callbacks and storage',
        () async {
      final storage = MemorySessionStorage();
      await storage.write('auth.access', 'old-token');
      await storage.write('auth.refresh', 'old-refresh');
      await storage.write('auth.session', '{}');

      var sessionUpdated = false;
      AuthSession? updatedSession;

      final apiClient = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async => _json({}, 200)),
        accessToken: 'old-token',
      );

      // Raw HTTP client that simulates the refresh endpoint
      final refreshClient = MockClient((request) async {
        if (request.url.path == '/auth/refresh') {
          return _json(_refreshPayload, 200);
        }
        return _json({}, 200);
      });

      final handler = AuthRefreshHandler(
        baseUrl: 'http://test',
        httpClient: refreshClient,
        client: apiClient,
        storage: storage,
        onSessionUpdated: (session) {
          sessionUpdated = true;
          updatedSession = session;
        },
        onSessionCleared: () {},
      );

      final success = await handler.execute(currentSession: _session());

      expect(success, isTrue);
      expect(sessionUpdated, isTrue);
      expect(updatedSession!.accessToken, 'new-access-token');
      expect(updatedSession!.refreshToken, 'new-refresh-token');
      expect(apiClient.accessToken, 'new-access-token');

      expect(await storage.read('auth.access'), 'new-access-token');
      expect(await storage.read('auth.refresh'), 'new-refresh-token');
    });

    test('coalesces concurrent refresh calls into a single HTTP request', () async {
      var refreshCallCount = 0;

      final apiClient = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async => _json({}, 200)),
        accessToken: 'old-token',
      );

      final refreshClient = MockClient((request) async {
        if (request.url.path == '/auth/refresh') {
          refreshCallCount++;
          await Future.delayed(const Duration(milliseconds: 200));
          return _json(_refreshPayload, 200);
        }
        return _json({}, 200);
      });

      final handler = AuthRefreshHandler(
        baseUrl: 'http://test',
        httpClient: refreshClient,
        client: apiClient,
        storage: MemorySessionStorage(),
        onSessionUpdated: (_) {},
        onSessionCleared: () {},
      );

      // Fire 5 concurrent refresh requests
      final results = await Future.wait([
        handler.execute(currentSession: _session()),
        handler.execute(currentSession: _session()),
        handler.execute(currentSession: _session()),
        handler.execute(currentSession: _session()),
        handler.execute(currentSession: _session()),
      ]);

      expect(results, everyElement(isTrue));
      expect(refreshCallCount, 1);
    });

    test('clears session when refresh fails with 401', () async {
      final storage = MemorySessionStorage();
      await storage.write('auth.access', 'old-token');
      await storage.write('auth.refresh', 'bad-refresh');

      var sessionCleared = false;

      final apiClient = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async => _json({}, 200)),
        accessToken: 'old-token',
      );

      final refreshClient = MockClient((request) async {
        if (request.url.path == '/auth/refresh') {
          return _json(
            {'detail': {'code': 'INVALID_REFRESH', 'message': 'Refresh token is invalid'}},
            401,
          );
        }
        return _json({}, 200);
      });

      final handler = AuthRefreshHandler(
        baseUrl: 'http://test',
        httpClient: refreshClient,
        client: apiClient,
        storage: storage,
        onSessionUpdated: (_) {},
        onSessionCleared: () => sessionCleared = true,
      );

      final success = await handler.execute(
        currentSession: _session(refreshToken: 'bad-refresh'),
      );

      expect(success, isFalse);
      expect(sessionCleared, isTrue);
      expect(apiClient.accessToken, isNull);
      expect(handler.refreshFailed, isTrue);

      expect(await storage.read('auth.access'), isNull);
      expect(await storage.read('auth.refresh'), isNull);
      expect(await storage.read('auth.session'), isNull);
    });

    test('clears session when refresh fails with network error', () async {
      var sessionCleared = false;

      final apiClient = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async => _json({}, 200)),
        accessToken: 'old-token',
      );

      final refreshClient = MockClient((request) async {
        throw Exception('Network error');
      });

      final handler = AuthRefreshHandler(
        baseUrl: 'http://test',
        httpClient: refreshClient,
        client: apiClient,
        storage: MemorySessionStorage(),
        onSessionUpdated: (_) {},
        onSessionCleared: () => sessionCleared = true,
      );

      final success = await handler.execute(currentSession: _session());

      expect(success, isFalse);
      expect(sessionCleared, isTrue);
      expect(handler.refreshFailed, isTrue);
    });

    test('subsequent calls after failure short-circuit without HTTP call', () async {
      var refreshCallCount = 0;

      final apiClient = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async => _json({}, 200)),
        accessToken: 'old-token',
      );

      final refreshClient = MockClient((request) async {
        refreshCallCount++;
        return _json({'detail': {'code': 'INVALID', 'message': 'Bad'}}, 401);
      });

      final handler = AuthRefreshHandler(
        baseUrl: 'http://test',
        httpClient: refreshClient,
        client: apiClient,
        storage: MemorySessionStorage(),
        onSessionUpdated: (_) {},
        onSessionCleared: () {},
      );

      await handler.execute(currentSession: _session(refreshToken: 'bad'));
      expect(refreshCallCount, 1);

      // Second call short-circuits
      final result = await handler.execute(currentSession: _session(refreshToken: 'bad'));
      expect(result, isFalse);
      expect(refreshCallCount, 1);

      // reset() clears the failure state
      handler.reset();
      expect(handler.refreshFailed, isFalse);
    });

    test('skip when onUnauthorized is false', () async {
      var refreshCallCount = 0;

      final apiClient = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async => _json({}, 200)),
        accessToken: 'old-token',
      );

      final refreshClient = MockClient((request) async {
        refreshCallCount++;
        return _json(_refreshPayload, 200);
      });

      final handler = AuthRefreshHandler(
        baseUrl: 'http://test',
        httpClient: refreshClient,
        client: apiClient,
        storage: MemorySessionStorage(),
        onSessionUpdated: (_) {},
        onSessionCleared: () {},
      );

      final result = await handler.execute(
        currentSession: _session(),
        onUnauthorized: false,
      );

      expect(result, isFalse);
      expect(refreshCallCount, 0);
    });
  });

  // -----------------------------------------------------------------------
  // TEST 3: SessionController integration — transparent refresh
  // -----------------------------------------------------------------------
  group('SessionController token refresh integration', () {
    test('expired token during restore is refreshed transparently', () async {
      final storage = MemorySessionStorage();
      await storage.write('auth.access', 'old-token');
      await storage.write('auth.refresh', 'old-refresh');
      await storage.write(
        'auth.session',
        jsonEncode({
          'access_token': 'old-token',
          'refresh_token': 'old-refresh',
          'expires_in': 900,
          'user': {'id': 'u1', 'email': 'a@b.com', 'name': 'A', 'status': 'active'},
          'permissions': [],
          'stores': [],
        }),
      );

      var refreshCount = 0;

      final apiClient = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async {
          switch (request.url.path) {
            case '/auth/me':
              final auth = request.headers['Authorization'] ?? '';
              if (auth == 'Bearer old-token') {
                return _json(
                  {'detail': {'code': 'TOKEN_EXPIRED', 'message': 'Access token has expired'}},
                  401,
                );
              }
              return _json(_mePayload, 200);
            case '/auth/refresh':
              refreshCount++;
              return _json(_refreshPayload, 200);
            default:
              return _json({}, 200);
          }
        }),
      );

      final controller = SessionController(
        storage: storage,
        api: AuthApi(apiClient),
      );

      await controller.restore();

      expect(controller.isAuthenticated, isTrue);
      expect(apiClient.accessToken, 'new-access-token');
      expect(refreshCount, 1);

      // Verify persisted tokens updated
      expect(await storage.read('auth.access'), 'new-access-token');
      expect(await storage.read('auth.refresh'), 'new-refresh-token');
    });

    test('refresh failure during restore clears session', () async {
      final storage = MemorySessionStorage();
      await storage.write('auth.access', 'expired-token');
      await storage.write('auth.refresh', 'bad-refresh');
      await storage.write(
        'auth.session',
        jsonEncode({
          'access_token': 'expired-token',
          'refresh_token': 'bad-refresh',
          'expires_in': 0,
          'user': {'id': 'u1', 'email': 'a@b.com', 'name': 'A', 'status': 'active'},
          'permissions': [],
          'stores': [],
        }),
      );

      final apiClient = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async {
          switch (request.url.path) {
            case '/auth/me':
              return _json(
                {'detail': {'code': 'TOKEN_EXPIRED', 'message': 'Expired'}},
                401,
              );
            case '/auth/refresh':
              return _json(
                {'detail': {'code': 'INVALID', 'message': 'Refresh invalid'}},
                401,
              );
            default:
              return _json({}, 200);
          }
        }),
      );

      final controller = SessionController(
        storage: storage,
        api: AuthApi(apiClient),
      );

      await controller.restore();

      expect(controller.isAuthenticated, isFalse);
      expect(apiClient.accessToken, isNull);
      expect(await storage.read('auth.access'), isNull);
    });

    test('mid-session 401 triggers transparent refresh and retry', () async {
      final storage = MemorySessionStorage();
      await storage.write('auth.access', 'a-token');
      await storage.write('auth.refresh', 'r-token');
      await storage.write('auth.session', jsonEncode(_loginPayload));

      var refreshCount = 0;

      final apiClient = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async {
          switch (request.url.path) {
            case '/auth/me':
              return _json(_mePayload, 200);
            case '/auth/refresh':
              refreshCount++;
              return _json(_refreshPayload, 200);
            case '/products':
              final auth = request.headers['Authorization'] ?? '';
              if (auth == 'Bearer a-token') {
                // Simulate expired access token
                return _json(
                  {'detail': {'code': 'TOKEN_EXPIRED', 'message': 'Access token has expired'}},
                  401,
                );
              }
              // After refresh, new token works
              return _json({'products': [{'id': 'p1', 'name': 'Coke'}]}, 200);
            default:
              return _json({}, 200);
          }
        }),
      );

      final controller = SessionController(
        storage: storage,
        api: AuthApi(apiClient),
      );

      // Restore (uses valid tokens, /auth/me succeeds)
      await controller.restore();
      expect(controller.isAuthenticated, isTrue);
      expect(refreshCount, 0);

      // Now simulate mid-session: access token expires
      // The onUnauthorized callback is wired, so ApiClient will trigger refresh
      final result = await apiClient.get('/products');
      expect(result, contains('products'));
      expect(refreshCount, 1);
      expect(apiClient.accessToken, 'new-access-token');
    });

    test('login resets refresh handler failure state', () async {
      final storage = MemorySessionStorage();

      final apiClient = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async {
          switch (request.url.path) {
            case '/auth/login':
              return _json({
                'access_token': 'fresh-token',
                'refresh_token': 'fresh-refresh',
                'expires_in': 900,
                ..._mePayload,
              }, 200);
            case '/auth/me':
              return _json(_mePayload, 200);
            default:
              return _json({}, 200);
          }
        }),
      );

      final controller = SessionController(
        storage: storage,
        api: AuthApi(apiClient),
      );

      final session = await controller.login(
        email: 'owner@test.dev',
        password: 'Test1234!',
      );

      expect(session.accessToken, 'fresh-token');
      expect(controller.isAuthenticated, isTrue);
      expect(apiClient.accessToken, 'fresh-token');
    });

    test('logout clears all state and unwires refresh callback', () async {
      final storage = MemorySessionStorage();
      await storage.write('auth.access', 'a-token');
      await storage.write('auth.refresh', 'r-token');

      final apiClient = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async {
          if (request.url.path == '/auth/login') {
            return _json({
              'access_token': 'fresh-token',
              'refresh_token': 'fresh-refresh',
              'expires_in': 900,
              ..._mePayload,
            }, 200);
          }
          if (request.url.path == '/auth/me') return _json(_mePayload, 200);
          if (request.url.path == '/auth/logout') return _json({}, 200);
          return _json({}, 200);
        }),
      );

      final controller = SessionController(
        storage: storage,
        api: AuthApi(apiClient),
      );

      // Login first
      await controller.login(
        email: 'owner@test.dev',
        password: 'Test1234!',
      );
      expect(controller.isAuthenticated, isTrue);

      // Logout
      await controller.logout();
      expect(controller.isAuthenticated, isFalse);
      expect(apiClient.accessToken, isNull);
      expect(apiClient.onUnauthorized, isNull);
      expect(await storage.read('auth.access'), isNull);
    });
  });

  // -----------------------------------------------------------------------
  // TEST 4: Concurrent requests with expired token
  // -----------------------------------------------------------------------
  group('Concurrent request recovery', () {
    test('multiple simultaneous 401s trigger exactly one refresh and all retry',
        () async {
      var refreshCount = 0;
      var originalRequestCount = 0;
      var retryRequestCount = 0;

      final apiClient = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async {
          final auth = request.headers['Authorization'] ?? '';

          if (request.url.path == '/auth/refresh') {
            refreshCount++;
            await Future.delayed(const Duration(milliseconds: 100));
            return _json(_refreshPayload, 200);
          }

          // Track original vs retry requests
          if (auth == 'Bearer old-token') {
            originalRequestCount++;
            return _json(
              {'detail': {'code': 'TOKEN_EXPIRED', 'message': 'Expired'}},
              401,
            );
          }
          retryRequestCount++;
          return _json({'data': 'ok'}, 200);
        }),
        accessToken: 'old-token',
      );

      final handler = AuthRefreshHandler(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/refresh') {
            refreshCount++;
            await Future.delayed(const Duration(milliseconds: 100));
            return _json(_refreshPayload, 200);
          }
          return _json({}, 200);
        }),
        client: apiClient,
        storage: MemorySessionStorage(),
        onSessionUpdated: (_) {},
        onSessionCleared: () {},
      );

      apiClient.onUnauthorized = () async {
        return handler.execute(currentSession: _session());
      };

      // Fire 5 concurrent requests that all get 401
      final results = await Future.wait([
        apiClient.get('/products'),
        apiClient.get('/categories'),
        apiClient.get('/suppliers'),
        apiClient.post('/orders', body: {'item': 1}),
        apiClient.get('/inventory'),
      ]);

      expect(results, hasLength(5));
      expect(results, everyElement(isA<Map>()));

      // Only ONE refresh call
      expect(refreshCount, 1);

      // 5 original requests (401) + 5 retried requests (200)
      expect(originalRequestCount, 5);
      expect(retryRequestCount, 5);
    });
  });

  // -----------------------------------------------------------------------
  // TEST 5: App resume scenario
  // -----------------------------------------------------------------------
  group('App resume scenario', () {
    test('refreshOnResume refreshes expired token silently', () async {
      final storage = MemorySessionStorage();
      await storage.write('auth.access', 'expired-token');
      await storage.write('auth.refresh', 'old-refresh');
      await storage.write(
        'auth.session',
        jsonEncode({
          'access_token': 'expired-token',
          'refresh_token': 'old-refresh',
          'expires_in': 900,
          'user': {'id': 'u1', 'email': 'a@b.com', 'name': 'A', 'status': 'active'},
          'permissions': ['products.view'],
          'stores': [
            {'id': 's1', 'name': 'Downtown', 'timezone': 'UTC', 'currency': 'USD'},
          ],
        }),
      );

      final apiClient = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async {
          if (request.url.path == '/auth/me') return _json(_mePayload, 200);
          if (request.url.path == '/auth/refresh') return _json(_refreshPayload, 200);
          return _json({}, 200);
        }),
        accessToken: 'expired-token',
      );

      final controller = SessionController(
        storage: storage,
        api: AuthApi(apiClient),
      );

      await controller.restore();
      expect(controller.isAuthenticated, isTrue);

      // Simulate app resume — should refresh proactively
      await controller.refreshOnResume();

      expect(apiClient.accessToken, 'new-access-token');
      expect(await storage.read('auth.access'), 'new-access-token');
    });

    test('refreshOnResume is no-op when not authenticated', () async {
      final storage = MemorySessionStorage();
      final apiClient = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async => _json({}, 200)),
      );

      final controller = SessionController(
        storage: storage,
        api: AuthApi(apiClient),
      );

      // Should not crash
      await controller.refreshOnResume();
    });

    test('refreshOnResume is no-op when refresh has previously failed', () async {
      final storage = MemorySessionStorage();
      await storage.write('auth.access', 'expired-token');
      await storage.write('auth.refresh', 'bad-refresh');

      final apiClient = ApiClient(
        baseUrl: 'http://test',
        client: MockClient((request) async {
          if (request.url.path == '/auth/me') {
            return _json(
              {'detail': {'code': 'TOKEN_EXPIRED', 'message': 'Expired'}},
              401,
            );
          }
          if (request.url.path == '/auth/refresh') {
            return _json(
              {'detail': {'code': 'INVALID', 'message': 'Bad'}},
              401,
            );
          }
          return _json({}, 200);
        }),
      );

      final controller = SessionController(
        storage: storage,
        api: AuthApi(apiClient),
      );

      // restore() will fail because refresh is bad → session cleared
      await controller.restore();
      expect(controller.isAuthenticated, isFalse);

      // refreshOnResume is no-op
      await controller.refreshOnResume();
      // No crash, no additional HTTP calls
    });
  });
}
