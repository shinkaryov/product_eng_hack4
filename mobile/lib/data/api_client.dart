import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import '../core/config.dart';
import 'models.dart';

/// Error from the backend, or a network failure (status 0).
class ApiException implements Exception {
  ApiException(this.status, this.detail);
  final int status;
  final String detail;

  bool get isNetwork => status == 0;
  bool get isUnauthorized => status == 401;
  bool get isNotFound => status == 404;
  bool get isConflict => status == 409;

  /// Copy for the UI, never raw server text for 5xx.
  String get message {
    if (isNetwork) return 'Can’t reach FamilyDoc. Check your connection and try again.';
    if (status == 429) return 'Too many attempts. Try again in a minute.';
    if (status == 413) return 'This file is too large.';
    if (status == 415) return 'This file type isn’t supported. Use PDF, JPG or PNG.';
    if (status >= 500) return 'Something went wrong on our side. Try again in a moment.';
    return detail;
  }

  @override
  String toString() => 'ApiException($status, $detail)';
}

/// Keeps the refresh token in Keychain/Keystore; the access token only in memory.
class TokenStore {
  TokenStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const _key = 'fd_refresh_token';

  String? access;

  Future<String?> readRefresh() async {
    try {
      return await _storage.read(key: _key);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(TokenPair t) async {
    access = t.access;
    await _storage.write(key: _key, value: t.refresh);
  }

  Future<void> clear() async {
    access = null;
    await _storage.delete(key: _key);
  }
}

/// Thin REST client over `http`. One refresh-and-retry on 401.
class ApiClient {
  ApiClient({required this.tokens, http.Client? client, String? baseUrl})
      : _http = client ?? http.Client(),
        baseUrl = baseUrl ?? AppConfig.apiBaseUrl;

  final TokenStore tokens;
  final http.Client _http;
  final String baseUrl;

  /// Called when the session can't be refreshed (go to Sign in).
  void Function()? onSessionExpired;

  Future<TokenPair>? _refreshing;

  Uri uri(String path, [Map<String, Object?>? query]) {
    final q = <String, String>{};
    query?.forEach((k, v) {
      if (v != null) q[k] = v.toString();
    });
    return Uri.parse('$baseUrl/v1$path').replace(queryParameters: q.isEmpty ? null : q);
  }

  Map<String, String> get authHeaders =>
      {if (tokens.access != null) HttpHeaders.authorizationHeader: 'Bearer ${tokens.access}'};

  Future<dynamic> get(String path, {Map<String, Object?>? query}) => _send('GET', path, query: query);
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body: body);
  Future<dynamic> patch(String path, Object body) => _send('PATCH', path, body: body);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  /// Unauthenticated JSON POST (login/register/refresh).
  Future<dynamic> postPublic(String path, Object body) => _send('POST', path, body: body, auth: false);

  Future<dynamic> _send(String method, String path,
      {Map<String, Object?>? query, Object? body, bool auth = true, bool retried = false}) async {
    final req = http.Request(method, uri(path, query));
    req.headers[HttpHeaders.acceptHeader] = 'application/json';
    if (auth) req.headers.addAll(authHeaders);
    if (body != null) {
      req.headers[HttpHeaders.contentTypeHeader] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await _execute(() => _http.send(req));
    if (res.statusCode == 401 && auth && !retried) {
      await refresh();
      return _send(method, path, query: query, body: body, auth: auth, retried: true);
    }
    return _decode(res);
  }

  /// Multipart upload: POST /documents.
  Future<Map<String, dynamic>> upload(String path,
      {required List<int> bytes, required String filename, required String mediaType, Map<String, String>? fields, bool retried = false}) async {
    final req = http.MultipartRequest('POST', uri(path));
    req.headers.addAll(authHeaders);
    req.headers[HttpHeaders.acceptHeader] = 'application/json';
    if (fields != null) req.fields.addAll(fields);
    final parts = mediaType.split('/');
    req.files.add(http.MultipartFile.fromBytes('file', bytes,
        filename: filename, contentType: MediaType(parts.first, parts.last)));
    final res = await _execute(() => _http.send(req), timeout: const Duration(seconds: 60));
    if (res.statusCode == 401 && !retried) {
      await refresh();
      return upload(path, bytes: bytes, filename: filename, mediaType: mediaType, fields: fields, retried: true);
    }
    return (await _decode(res) as Map).cast<String, dynamic>();
  }

  /// Raw bytes (GET /documents/{id}/file).
  Future<List<int>> download(String path, {bool retried = false}) async {
    final req = http.Request('GET', uri(path))..headers.addAll(authHeaders);
    final res = await _execute(() => _http.send(req), timeout: const Duration(seconds: 60));
    if (res.statusCode == 401 && !retried) {
      await refresh();
      return download(path, retried: true);
    }
    if (res.statusCode >= 400) await _decode(res);
    return res.bodyBytes;
  }

  Future<http.Response> _execute(Future<http.StreamedResponse> Function() send,
      {Duration timeout = const Duration(seconds: 30)}) async {
    try {
      final streamed = await send().timeout(timeout);
      return await http.Response.fromStream(streamed);
    } on SocketException {
      throw ApiException(0, 'network');
    } on TimeoutException {
      throw ApiException(0, 'timeout');
    } on http.ClientException {
      throw ApiException(0, 'network');
    }
  }

  dynamic _decode(http.Response res) {
    final text = utf8.decode(res.bodyBytes);
    final dynamic json = text.isEmpty ? null : _tryJson(text);
    if (res.statusCode >= 200 && res.statusCode < 300) return json;
    throw ApiException(res.statusCode, _detail(json) ?? 'Request failed (${res.statusCode})');
  }

  static dynamic _tryJson(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return s;
    }
  }

  static String? _detail(dynamic json) {
    if (json is Map && json['detail'] != null) {
      final d = json['detail'];
      if (d is String) return d;
      if (d is List && d.isNotEmpty && d.first is Map) return (d.first as Map)['msg']?.toString();
    }
    return json is String && json.isNotEmpty ? json : null;
  }

  /// Rotates the token pair. Concurrent callers share one refresh.
  Future<TokenPair> refresh() {
    return _refreshing ??= () async {
      try {
        final rt = await tokens.readRefresh();
        if (rt == null) throw ApiException(401, 'No session');
        final json = await _send('POST', '/auth/refresh', body: {'refresh_token': rt}, auth: false, retried: true);
        final pair = TokenPair.fromJson((json as Map).cast<String, dynamic>());
        await tokens.save(pair);
        return pair;
      } on ApiException catch (e) {
        if (e.isUnauthorized) {
          await tokens.clear();
          onSessionExpired?.call();
        }
        rethrow;
      } finally {
        _refreshing = null;
      }
    }();
  }
}
