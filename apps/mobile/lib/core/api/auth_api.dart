import '../api_client.dart';
import '../models/auth_models.dart';

/// Auth endpoints wrapper.
class AuthApi {
  const AuthApi(this._client);

  final ApiClient _client;

  ApiClient get client => _client;

  Future<AuthSession> login({
    required String email,
    required String password,
    required String deviceUuid,
    String? deviceName,
    String? platform,
  }) async {
    final json = await _client.post(
      '/auth/login',
      body: {
        'email': email,
        'password': password,
        'device': {
          'device_uuid': deviceUuid,
          'name': deviceName,
          'platform': platform,
        },
      },
    );
    return AuthSession.fromJson(json);
  }

  /// Refresh-token rotation. Returns the new token pair.
  Future<({String accessToken, String refreshToken, int expiresIn})> refresh(
    String refreshToken,
  ) async {
    final json = await _client.post('/auth/refresh', body: {'refresh_token': refreshToken});
    return (
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
      expiresIn: (json['expires_in'] as num).toInt(),
    );
  }

  /// Current identity + scope. Used to hydrate a restored session.
  Future<MeInfo> me() async {
    final json = await _client.get('/auth/me');
    return MeInfo.fromJson(json);
  }

  Future<void> logout() async {
    await _client.post('/auth/logout');
  }
}
