import 'dart:async';

import 'package:dio/dio.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import '../config/env.dart';
import '../storage/secure_storage.dart';
import '../navigation/nav_service.dart';
import '../services/offline_action_queue_service.dart';

class ApiClient {
  ApiClient._();

  static Dio? _instance;

  static Dio get instance {
    _instance ??= _build();
    return _instance!;
  }

  // Per-request timeout overrides — pass via Options(extra: {...})
  // Default timeouts tuned for Ghana 3G: fast connect, generous receive
  static const _connectTimeout = Duration(seconds: 10);
  static const _receiveTimeout =
      Duration(seconds: 30); // longer for list endpoints on slow networks

  static Dio _build() {
    final dio = Dio(BaseOptions(
      baseUrl: Env.apiBaseUrl,
      connectTimeout: _connectTimeout,
      receiveTimeout: _receiveTimeout,
      headers: {'Content-Type': 'application/json'},
    ));

    dio.interceptors.add(_AuthInterceptor(dio));
    return dio;
  }

  // Auth helpers
  static Future<Response> post(String path, Map<String, dynamic> data) =>
      instance.post(path, data: data);

  /// Multipart file upload — uses a longer receive timeout (60s) for photo uploads on Ghana 3G.
  static Future<Response> upload(String path, FormData formData) =>
      instance.post(
        path,
        data: formData,
        options: Options(
          receiveTimeout: const Duration(seconds: 60),
          contentType: 'multipart/form-data',
        ),
      );

  static Future<Response<dynamic>> send(
    String method,
    String path, {
    dynamic data,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? extra,
  }) {
    return instance.request(
      path,
      data: data,
      options: Options(
        method: method,
        headers: headers,
        extra: extra,
      ),
    );
  }

  static Future<Response> get(String path, {Map<String, dynamic>? params}) =>
      instance.get(path, queryParameters: params);

  static Future<Response> put(String path, [Map<String, dynamic>? data]) =>
      instance.put(path, data: data);

  static Future<Response> patch(String path, [Map<String, dynamic>? data]) =>
      instance.patch(path, data: data);

  static Future<Response> delete(String path) => instance.delete(path);
}

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._dio);
  final Dio _dio;

  // Single in-flight refresh shared by all concurrent 401s. Followers await
  // the same future and retry with the new token instead of failing outright.
  Completer<String?>? _refreshCompleter;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // Only add token if not already present or explicitly cleared
    if (!options.headers.containsKey('Authorization')) {
      final token = await SecureStorage.getAccessToken();
      if (token != null) {
        options.headers['Authorization'] = 'Bearer $token';
      }
    }
    if (_needsIdempotency(options)) {
      final idempKey = await _buildIdempotencyKey(options);
      options.headers.putIfAbsent('Idempotency-Key', () => idempKey);
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    try {
      await FirebaseCrashlytics.instance.recordError(
        err,
        err.stackTrace,
        reason: 'API request failed',
        information: [
          'method=${err.requestOptions.method}',
          'path=${err.requestOptions.path}',
          'status=${err.response?.statusCode}',
        ],
      );
    } catch (_) {}

    if (_isOfflineFailure(err) &&
        OfflineActionQueueService.shouldQueue(err.requestOptions)) {
      await OfflineActionQueueService.enqueue(err.requestOptions);
      handler.resolve(
        Response(
          requestOptions: err.requestOptions,
          statusCode: 202,
          data: const {
            'success': true,
            'queued': true,
            'offline': true,
          },
        ),
      );
      return;
    }

    final isRefreshCall =
        err.requestOptions.path.contains('/api/auth/refresh');
    final alreadyRetried = err.requestOptions.extra['__authRetried'] == true;

    if (err.response?.statusCode == 401 && !isRefreshCall && !alreadyRetried) {
      final isInitiator = _refreshCompleter == null;
      final newToken = await _refreshAccessToken();

      if (newToken != null) {
        final opts = err.requestOptions;
        opts.headers['Authorization'] = 'Bearer $newToken';
        opts.extra['__authRetried'] = true;
        try {
          handler.resolve(await _dio.fetch(opts));
        } on DioException catch (retryErr) {
          handler.next(retryErr);
        }
        return;
      }

      // Refresh failed — session is over. Only the initiator clears storage
      // and navigates, so N concurrent failures don't stack N /login pushes.
      if (isInitiator) {
        await SecureStorage.clearAll();
        NavService.pushNamedAndRemoveUntil('/login');
      }
      handler.next(err);
      return;
    }

    handler.next(err);
  }

  /// Returns a fresh access token, or null if the session cannot be renewed.
  /// Concurrent callers share one refresh request.
  Future<String?> _refreshAccessToken() {
    final inflight = _refreshCompleter;
    if (inflight != null) return inflight.future;

    final completer = _refreshCompleter = Completer<String?>();
    () async {
      try {
        final refreshToken = await SecureStorage.getRefreshToken();
        if (refreshToken == null) {
          completer.complete(null);
          return;
        }
        final res = await _dio.post(
          '/api/auth/refresh',
          data: {'refreshToken': refreshToken},
          options: Options(
            headers: {'Authorization': ''},
            extra: {'skipOfflineQueue': true},
          ),
        );
        final data = res.data['data'];
        await SecureStorage.saveTokens(
          accessToken: data['accessToken'],
          refreshToken: data['refreshToken'],
        );
        await SecureStorage.saveUser(Map<String, dynamic>.from(data['user']));
        completer.complete(data['accessToken'] as String);
      } catch (_) {
        completer.complete(null);
      } finally {
        _refreshCompleter = null;
      }
    }();
    return completer.future;
  }

  bool _needsIdempotency(RequestOptions options) {
    if (options.method.toUpperCase() != 'POST') return false;
    final path = options.path;
    return path == '/api/bookings' ||
        path == '/api/payments/initialize' ||
        path == '/api/payments/verify' ||
        path == '/api/payments/wallet/top-up/initialize' ||
        path == '/api/payments/wallet/top-up/verify' ||
        path.contains('/review') ||
        path.contains('/rating') ||
        path == '/api/support/tickets';
  }

  Future<String> _buildIdempotencyKey(RequestOptions options) async {
    final user = await SecureStorage.getUser();
    final userId = user?['id'] as String? ?? 'anon';
    final payload = _stableStringify(options.data);
    // 10-minute bucket: identical taps/timeout-retries within the window
    // dedupe; the same booking placed on another day is a new intent.
    // (Queued offline replays keep their original header regardless.)
    final bucket = DateTime.now().millisecondsSinceEpoch ~/ 600000;
    final seed = '$userId:${options.method}:${options.path}:$bucket:$payload';
    // Two independent 32-bit FNV-1a hashes -> 64-bit key. String.hashCode is
    // only 32 bits and not guaranteed stable across runs; this is both.
    return _fnv1a32(seed, 0x811c9dc5) + _fnv1a32(seed, 0x811c9dc5 ^ 0x5bd1e995);
  }

  String _fnv1a32(String input, int offsetBasis) {
    var hash = offsetBasis & 0xFFFFFFFF;
    for (final unit in input.codeUnits) {
      hash ^= unit & 0xFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
      hash ^= unit >> 8;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _stableStringify(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return '{${keys.map((key) => '"$key":${_stableStringify(value[key])}').join(',')}}';
    }
    if (value is List) {
      return '[${value.map(_stableStringify).join(',')}]';
    }
    if (value == null) return 'null';
    if (value is String) return '"$value"';
    return value.toString();
  }

  bool _isOfflineFailure(DioException err) {
    return err.type == DioExceptionType.connectionError ||
        err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        (err.error?.toString().toLowerCase().contains('socket') ?? false);
  }
}
