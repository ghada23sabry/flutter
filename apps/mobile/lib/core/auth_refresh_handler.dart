import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'models/auth_models.dart';
import 'session_store.dart';

/// Single source of truth for token refresh with concurrency control.
///
/// When multiple requests receive a 401 simultaneously, only one refresh
/// is executed. All waiters share the same [Completer] and are notified
/// when the refresh completes (success or failure).
///
/// The refresh HTTP call bypasses [ApiClient] entirely (uses a raw
/// [http.Client]) to prevent the retry interceptor from recursing.
class AuthRefreshHandler {
  AuthRefreshHandler({
    required String baseUrl,
    required http.Client httpClient,
    required ApiClient client,
    required SessionStorage storage,
    required void Function(AuthSession session) onSessionUpdated,
    required void Function() onSessionCleared,
  })  : _baseUrl = baseUrl,
        _httpClient = httpClient,
        _client = client,
        _storage = storage,
        _onSessionUpdated = onSessionUpdated,
        _onSessionCleared = onSessionCleared;

  static const String _accessKey = 'auth.access';
  static const String _refreshKey = 'auth.refresh';
  static const String _sessionKey = 'auth.session';

  final String _baseUrl;
  final http.Client _httpClient;
  final ApiClient _client;
  final SessionStorage _storage;
  final void Function(AuthSession session) _onSessionUpdated;
  final void Function() _onSessionCleared;

  Completer<void>? _refreshing;
  bool _refreshFailed = false;

  /// Whether a refresh is currently in progress.
  bool get isRefreshing => _refreshing != null;

  /// Whether the last refresh attempt failed (session was cleared).
  bool get refreshFailed => _refreshFailed;

  /// Execute a token refresh, coalescing concurrent callers.
  ///
  /// Returns `true` if the refresh succeeded and the caller should retry.
  /// Returns `false` if the refresh failed and the caller should propagate
  /// the error.
  ///
  /// The [currentSession] provides the refresh token to rotate.
  /// The [onUnauthorized] flag indicates this was triggered by a 401 response.
  Future<bool> execute({
    required AuthSession currentSession,
    bool onUnauthorized = true,
  }) async {
    if (!onUnauthorized) return false;
    if (_refreshFailed) return false;

    // Coalesce concurrent callers: if a refresh is already in flight,
    // all subsequent callers wait on the same Completer.
    if (_refreshing != null) {
      await _refreshing!.future;
      return !_refreshFailed;
    }

    _refreshing = Completer<void>();

    try {
      // Call /auth/refresh directly via raw HTTP client — this bypasses
      // ApiClient's retry interceptor to prevent infinite recursion.
      final response = await _httpClient.post(
        Uri.parse('$_baseUrl/auth/refresh'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({'refresh_token': currentSession.refreshToken}),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final rotatedAccessToken = json['access_token'] as String;
        final rotatedRefreshToken = json['refresh_token'] as String;

        final updated = currentSession.copyWith(
          accessToken: rotatedAccessToken,
          refreshToken: rotatedRefreshToken,
        );

        _client.accessToken = rotatedAccessToken;
        _onSessionUpdated(updated);

        await _storage.write(_accessKey, rotatedAccessToken);
        await _storage.write(_refreshKey, rotatedRefreshToken);
        await _storage.write(_sessionKey, jsonEncode(updated.toJson()));

        _refreshFailed = false;
        _refreshing!.complete();
        _refreshing = null;
        return true;
      }
    } catch (_) {
      // Network error or parse failure.
    }

    // Failure path — complete synchronously so callers see updated state.
    _refreshFailed = true;
    _client.accessToken = null;
    _refreshing!.complete();
    _refreshing = null;
    _onSessionCleared();
    // Storage cleanup is fire-and-forget; in-memory state is authoritative.
    _clearStorage();
    return false;
  }

  /// Reset the failed state (e.g. after a fresh login).
  void reset() {
    _refreshFailed = false;
  }

  Future<void> _clearStorage() async {
    await _storage.delete(_accessKey);
    await _storage.delete(_refreshKey);
    await _storage.delete(_sessionKey);
  }
}
