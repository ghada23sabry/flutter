import 'dart:async';

class _CacheEntry<T> {
  final T data;
  final DateTime expiresAt;

  _CacheEntry(this.data, this.expiresAt);

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class AppCache {
  AppCache._();

  static final AppCache instance = AppCache._();

  final Map<String, _CacheEntry<dynamic>> _store = {};

  Future<T> get<T>(String key, Duration ttl, Future<T> Function() fetch) async {
    final entry = _store[key];
    if (entry != null && !entry.isExpired) {
      return entry.data as T;
    }
    final data = await fetch();
    _store[key] = _CacheEntry(data, DateTime.now().add(ttl));
    return data;
  }

  void invalidate(String key) {
    _store.remove(key);
  }

  void invalidatePrefix(String prefix) {
    _store.keys.where((k) => k.startsWith(prefix)).toList().forEach(_store.remove);
  }

  void clear() {
    _store.clear();
  }
}
