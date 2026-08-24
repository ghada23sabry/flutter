import 'dart:convert';

import 'package:http/http.dart' as http;

/// Raised for any non-2xx API response carrying the backend error envelope
/// `{"detail": {"code": ..., "message": ...}}`.
class ApiException implements Exception {
  const ApiException(this.statusCode, this.code, this.message);

  final int statusCode;
  final String code;
  final String message;

  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;
  bool get isConflict => statusCode == 409;

  @override
  String toString() => message;
}

/// Minimal typed HTTP client for the VisionStock API.
class ApiClient {
  ApiClient({required this.baseUrl, http.Client? client, this.accessToken})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  /// Expose the raw HTTP client for cases where retry-on-401 must be
  /// bypassed (e.g. the /auth/refresh call itself).
  http.Client get rawClient => _client;
  String? accessToken;

  /// Callback invoked when a request receives a 401 (expired token).
  ///
  /// The callback must perform a token refresh, update [accessToken],
  /// and return `true` if the refresh succeeded (caller should retry),
  /// or `false` if it failed (caller should propagate the error).
  ///
  /// This is intentionally a simple function callback, not an interface,
  /// to avoid coupling ApiClient to SessionController.
  Future<bool> Function()? onUnauthorized;

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) async {
    return _requestWithRetry((token) async {
      final headers = _headersForToken(token);
      final response = await _client.get(_uri(path, query), headers: headers);
      return _decode(response);
    });
  }

  Future<List<dynamic>> getList(String path, {Map<String, dynamic>? query}) async {
    return _requestWithRetry((token) async {
      final headers = _headersForToken(token);
      final response = await _client.get(_uri(path, query), headers: headers);
      return _decodeList(response);
    });
  }

  Future<Map<String, dynamic>> post(String path, {Object? body, Map<String, dynamic>? query}) async {
    return _requestWithRetry((token) async {
      final headers = _headersForToken(token, hasBody: body != null);
      final response = await _client.post(
        _uri(path, query),
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      );
      return _decode(response);
    });
  }

  Future<Map<String, dynamic>> postBytes(
    String path, {
    required List<int> bytes,
    Map<String, dynamic>? query,
    String contentType = 'application/octet-stream',
  }) async {
    return _requestWithRetry((token) async {
      final headers = _headersForToken(token, hasBody: true);
      headers['Content-Type'] = contentType;
      final response = await _client.post(
        _uri(path, query),
        headers: headers,
        body: bytes,
      );
      return _decode(response);
    });
  }

  Future<Map<String, dynamic>> patch(String path, {Object? body, Map<String, dynamic>? query}) async {
    return _requestWithRetry((token) async {
      final headers = _headersForToken(token, hasBody: body != null);
      final response = await _client.patch(
        _uri(path, query),
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      );
      return _decode(response);
    });
  }

  Future<Map<String, dynamic>> delete(String path, {Map<String, dynamic>? query}) async {
    return _requestWithRetry((token) async {
      final headers = _headersForToken(token, hasBody: false);
      final response = await _client.delete(_uri(path, query), headers: headers);
      return _decode(response);
    });
  }

  /// Upload a file via multipart/form-data (for image uploads, etc.).
  Future<Map<String, dynamic>> uploadFile(
    String path, {
    required String filePath,
    required String fileName,
    Map<String, dynamic>? query,
  }) async {
    return _requestWithRetry((token) async {
      final uri = _uri(path, query);
      final request = http.MultipartRequest('POST', uri);
      if (token.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $token';
      }
      request.headers['Accept'] = 'application/json';
      final file = await http.MultipartFile.fromPath('file', filePath, filename: fileName);
      request.files.add(file);
      final streamed = await _client.send(request);
      final response = await http.Response.fromStream(streamed);
      return _decode(response);
    });
  }

  /// Executes [fn] with the current [accessToken]. On a 401, invokes
  /// [onUnauthorized] to refresh the token, then retries [fn] exactly once.
  Future<T> _requestWithRetry<T>(Future<T> Function(String token) fn) async {
    final handler = onUnauthorized;
    try {
      return await fn(accessToken ?? '');
    } on ApiException catch (e) {
      if (!e.isUnauthorized || handler == null) rethrow;

      final refreshed = await handler();
      if (!refreshed) rethrow;

      // Retry once with the new token.
      return await fn(accessToken ?? '');
    }
  }

  Uri _uri(String path, Map<String, dynamic>? query) {
    final uri = Uri.parse('$baseUrl$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(
      queryParameters: {
        ...uri.queryParameters,
        for (final e in query.entries)
          if (e.value != null) e.key: e.value.toString(),
      },
    );
  }

  Map<String, String> _headersForToken(String token, {bool hasBody = false}) => {
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        'Accept': 'application/json',
        if (hasBody) 'Content-Type': 'application/json',
      };

  Map<String, dynamic> _decode(http.Response response) {
    final decoded = _decodeBody(response);
    if (decoded is Map<String, dynamic>) return decoded;
    if (response.statusCode >= 200 && response.statusCode < 300) return <String, dynamic>{};
    throw ApiException(
      response.statusCode,
      'HTTP_${response.statusCode}',
      'Request failed (${response.statusCode})',
    );
  }

  List<dynamic> _decodeList(http.Response response) {
    final decoded = _decodeBody(response);
    if (decoded is List) return decoded;
    if (response.statusCode >= 200 && response.statusCode < 300) return <dynamic>[];
    throw ApiException(
      response.statusCode,
      'HTTP_${response.statusCode}',
      'Request failed (${response.statusCode})',
    );
  }

  /// Shared decode + error-envelope handling.
  Object? _decodeBody(http.Response response) {
    Object? decoded;
    try {
      decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      decoded = null;
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }

    if (decoded is Map && decoded['detail'] is Map) {
      final detail = decoded['detail'] as Map;
      final code = detail['code'];
      final message = detail['message'];
      throw ApiException(
        response.statusCode,
        code is String ? code : 'HTTP_${response.statusCode}',
        message is String ? message : 'Request failed (${response.statusCode})',
      );
    }

    throw ApiException(
      response.statusCode,
      'HTTP_${response.statusCode}',
      'Request failed (${response.statusCode})',
    );
  }
}
