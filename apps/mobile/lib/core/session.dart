import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'api/auth_api.dart';
import 'api_client.dart';
import 'models/auth_models.dart';
import 'session_store.dart';

/// Owns the app-wide auth state and its persistence.
class SessionController extends ChangeNotifier {
  SessionController({required this._storage, required this._api});

  static const String _accessKey = 'auth.access';
  static const String _refreshKey = 'auth.refresh';
  static const String _sessionKey = 'auth.session';
  static const String _deviceUuidKey = 'device.uuid';

  final SessionStorage _storage;
  final AuthApi _api;
  AuthSession? _current;
  String? _deviceUuid;
  String? _selectedStoreId;

  /// Shared underlying HTTP client; feature APIs are built on top of it.
  ApiClient get apiClient => _api.client;

  AuthSession? get current => _current;

  bool get isAuthenticated => _current != null;

  bool hasPermission(String code) => _current?.hasPermission(code) ?? false;

  /// Stores the authenticated user can access, in API order.
  List<StoreInfo> get stores => _current?.stores ?? const [];

  /// The store the catalog is scoped to. Defaults to the first accessible store.
  String get selectedStoreId {
    final id = _selectedStoreId;
    if (id != null && stores.any((s) => s.id == id)) return id;
    if (stores.isNotEmpty) return stores.first.id;
    return '';
  }

  StoreInfo? get selectedStore {
    for (final s in stores) {
      if (s.id == selectedStoreId) return s;
    }
    return null;
  }

  void selectStore(String storeId) {
    if (_selectedStoreId == storeId) return;
    _selectedStoreId = storeId;
    notifyListeners();
  }

  /// Restore a persisted session on app start.
  ///
  /// Builds the session from cached fragments first (so the app opens even
  /// offline), then best-effort re-hydrates permissions/stores from `/auth/me`.
  /// A 401 triggers refresh-token rotation; any network failure keeps the
  /// cached session intact.
  Future<void> restore() async {
    final access = await _storage.read(_accessKey);
    final refresh = await _storage.read(_refreshKey);
    _deviceUuid = await _storage.read(_deviceUuidKey);
    if (access != null && refresh != null) {
      try {
        final sessionJson = await _storage.read(_sessionKey);
        _current = sessionJson != null
            ? _restoreFromJson(sessionJson, access: access, refresh: refresh)
            : AuthSession.restored(accessToken: access, refreshToken: refresh);
        _api.client.accessToken = _current!.accessToken;
        await _hydrate();
      } catch (_) {
        // Corrupt or unreadable persisted session: clear it, re-login required.
        await _clear();
      }
    }
    notifyListeners();
  }

  Future<AuthSession> login({required String email, required String password}) async {
    final deviceId = await _ensureDeviceUuid();
    final session = await _api.login(
      email: email,
      password: password,
      deviceUuid: deviceId,
      platform: defaultTargetPlatform.name,
    );
    await _persist(session);
    _current = session;
    _api.client.accessToken = session.accessToken;
    if (session.stores.isNotEmpty) _selectedStoreId ??= session.stores.first.id;
    notifyListeners();
    return session;
  }

  Future<void> logout() async {
    try {
      await _api.logout();
    } catch (_) {
      // Best-effort server revoke; local session is still cleared.
    }
    await _clear();
    _current = null;
    _selectedStoreId = null;
    _api.client.accessToken = null;
    notifyListeners();
  }

  /// Refresh permissions/stores (and tokens if needed) after restore.
  Future<void> _hydrate() async {
    final session = _current;
    if (session == null) return;
    try {
      final me = await _api.me();
      _current = _current!.copyWith(
        user: me.user,
        permissions: me.permissions,
        stores: me.stores,
      );
      await _persist(_current!);
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        try {
          final rotated = await _api.refresh(session.refreshToken);
          _current = _current!.copyWith(
            accessToken: rotated.accessToken,
            refreshToken: rotated.refreshToken,
          );
          _api.client.accessToken = rotated.accessToken;
          final me = await _api.me();
          _current = _current!.copyWith(
            user: me.user,
            permissions: me.permissions,
            stores: me.stores,
          );
          await _persist(_current!);
        } catch (_) {
          await _clear();
        }
      }
      // Other failures keep the cached session.
    } catch (_) {
      // Network errors keep the cached session.
    }
  }

  AuthSession _restoreFromJson(String sessionJson, {required String access, required String refresh}) {
    final json = jsonDecode(sessionJson) as Map<String, dynamic>;
    return AuthSession.fromJson({...json, 'access_token': access, 'refresh_token': refresh});
  }

  Future<void> _persist(AuthSession session) async {
    await _storage.write(_accessKey, session.accessToken);
    await _storage.write(_refreshKey, session.refreshToken);
    await _storage.write(_sessionKey, jsonEncode(session.toJson()));
  }

  Future<void> _clear() async {
    await _storage.delete(_accessKey);
    await _storage.delete(_refreshKey);
    await _storage.delete(_sessionKey);
  }

  Future<String> _ensureDeviceUuid() async {
    if (_deviceUuid != null) return _deviceUuid!;
    final existing = await _storage.read(_deviceUuidKey);
    if (existing != null) {
      _deviceUuid = existing;
      return existing;
    }
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final id = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(_deviceUuidKey, id);
    _deviceUuid = id;
    return id;
  }
}
