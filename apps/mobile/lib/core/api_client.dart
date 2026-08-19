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
  String? accessToken;

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) async {
    final response = await _client.get(_uri(path, query), headers: _headers());
    return _decode(response);
  }

  /// GET returning a JSON array (list endpoints like `/categories`).
  Future<List<dynamic>> getList(String path, {Map<String, dynamic>? query}) async {
    final response = await _client.get(_uri(path, query), headers: _headers());
    return _decodeList(response);
  }

  Future<Map<String, dynamic>> post(String path, {Object? body, Map<String, dynamic>? query}) async {
    final response = await _client.post(
      _uri(path, query),
      headers: _headers(hasBody: body != null),
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(response);
  }

  /// POST a raw (non-JSON) payload, e.g. scan-image bytes for `POST /ai/scans/{id}/process`.
  Future<Map<String, dynamic>> postBytes(
    String path, {
    required List<int> bytes,
    Map<String, dynamic>? query,
    String contentType = 'application/octet-stream',
  }) async {
    final response = await _client.post(
      _uri(path, query),
      headers: {..._headers(hasBody: true), 'Content-Type': contentType},
      body: bytes,
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> patch(String path, {Object? body, Map<String, dynamic>? query}) async {
    final response = await _client.patch(
      _uri(path, query),
      headers: _headers(hasBody: body != null),
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> delete(String path, {Map<String, dynamic>? query}) async {
    final response = await _client.delete(_uri(path, query), headers: _headers());
    return _decode(response);
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

  Map<String, String> _headers({bool hasBody = true}) => {
        if (accessToken != null) 'Authorization': 'Bearer $accessToken',
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
