/// API response models for the auth flow.
class UserInfo {
  const UserInfo({required this.id, required this.email, required this.name, required this.status});

  factory UserInfo.fromJson(Map<String, dynamic> json) => UserInfo(
        id: json['id'] as String? ?? '',
        email: json['email'] as String? ?? '',
        name: json['name'] as String? ?? '',
        status: json['status'] as String? ?? 'unknown',
      );

  factory UserInfo.empty() => const UserInfo(id: '', email: '', name: '', status: 'unknown');

  final String id;
  final String email;
  final String name;
  final String status;

  Map<String, dynamic> toJson() => {'id': id, 'email': email, 'name': name, 'status': status};
}

class StoreInfo {
  const StoreInfo({required this.id, required this.name, required this.timezone, required this.currency});

  factory StoreInfo.fromJson(Map<String, dynamic> json) => StoreInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        timezone: json['timezone'] as String,
        currency: json['currency'] as String,
      );

  final String id;
  final String name;
  final String timezone;
  final String currency;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'timezone': timezone,
        'currency': currency,
      };
}

/// Identity + access scope returned by `/auth/me`.
class MeInfo {
  const MeInfo({required this.user, required this.permissions, required this.stores});

  factory MeInfo.fromJson(Map<String, dynamic> json) => MeInfo(
        user: UserInfo.fromJson(json['user'] as Map<String, dynamic>),
        permissions: [
          for (final p in (json['permissions'] as List? ?? [])) p as String,
        ],
        stores: [
          for (final s in (json['stores'] as List? ?? []))
            StoreInfo.fromJson(s as Map<String, dynamic>),
        ],
      );

  final UserInfo user;
  final List<String> permissions;
  final List<StoreInfo> stores;
}

/// A completed login: tokens + identity + access scope.
class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.user,
    required this.permissions,
    required this.stores,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
        expiresIn: (json['expires_in'] as num).toInt(),
        user: UserInfo.fromJson(json['user'] as Map<String, dynamic>),
        permissions: [
          for (final p in (json['permissions'] as List? ?? [])) p as String,
        ],
        stores: [
          for (final s in (json['stores'] as List? ?? []))
            StoreInfo.fromJson(s as Map<String, dynamic>),
        ],
      );

  /// Restored session reconstructed from persisted fragments.
  factory AuthSession.restored({
    required String accessToken,
    required String refreshToken,
    Map<String, dynamic>? user,
    List<String> permissions = const [],
    List<StoreInfo> stores = const [],
  }) =>
      AuthSession(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresIn: 0,
        user: user == null ? UserInfo.empty() : UserInfo.fromJson(user),
        permissions: permissions,
        stores: stores,
      );

  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final UserInfo user;
  final List<String> permissions;
  final List<StoreInfo> stores;

  bool hasPermission(String code) => permissions.contains(code);

  AuthSession copyWith({
    String? accessToken,
    String? refreshToken,
    UserInfo? user,
    List<String>? permissions,
    List<StoreInfo>? stores,
  }) =>
      AuthSession(
        accessToken: accessToken ?? this.accessToken,
        refreshToken: refreshToken ?? this.refreshToken,
        expiresIn: expiresIn,
        user: user ?? this.user,
        permissions: permissions ?? this.permissions,
        stores: stores ?? this.stores,
      );

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_in': expiresIn,
        'user': user.toJson(),
        'permissions': permissions,
        'stores': [for (final s in stores) s.toJson()],
      };
}

