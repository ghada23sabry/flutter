import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Key/value persistence for session secrets and device identity.
abstract class SessionStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// Production storage: Keystore (Android) / Keychain (iOS).
class SecureSessionStorage implements SessionStorage {
  const SecureSessionStorage();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory storage for tests and previews (never in production).
class MemorySessionStorage implements SessionStorage {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}
