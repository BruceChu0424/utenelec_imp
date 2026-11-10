import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/interceptors/visitor_auth_interceptor.dart';
import 'package:uten_imp/core/network/visitor_session_event_bus.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'separate clients of one owner rotate the shared refresh token once',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final second = fixture.createClient();
      addTearDown(() => second.close(force: true));
      final firstRequest = fixture.request();
      await _until(() => fixture.refreshes.contains('refresh-A'));
      final secondRequest = second
          .post<dynamic>('/visitor/confirmation')
          .then<Object>(
            (response) => response,
            onError: (Object error) => error,
          );
      await _until(() => fixture.businessBearers.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fixture.refreshes, ['refresh-A']);
      fixture.release('A', 200);
      expect(await firstRequest, isA<Response<dynamic>>());
      expect(await secondRequest, isA<Response<dynamic>>());
      expect(fixture.refreshes, ['refresh-A']);
      expect(fixture.applied, 2);
    },
  );
  for (final status in [200, 401]) {
    test(
      'late visitor A refresh $status cannot replace or expire visitor B',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.close);
        var expirations = 0;
        final subscription = VisitorSessionEventBus.instance.onSessionExpired
            .listen((_) => expirations++);
        addTearDown(subscription.cancel);
        final old = fixture.request();
        await _until(() => fixture.refreshes.contains('refresh-A'));
        await fixture.login('B');
        fixture.release('A', status);
        final result = await old;
        expect(await fixture.storage.getVisitorAccessToken(), 'access-B');
        expect(await fixture.storage.getVisitorRefreshToken(), 'refresh-B');
        expect(result, isA<DioException>());
        expect(expirations, 0);
        expect(fixture.applied, 0);
        expect(fixture.businessBearers, ['Bearer access-A']);
      },
    );
  }

  test(
    'a delayed A 401 cannot refresh or replay as newly signed-in B',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      fixture.businessGate = Completer<void>();
      final old = fixture.request();
      await _until(() => fixture.businessBearers.isNotEmpty);
      await fixture.login('B');
      fixture.businessGate!.complete();
      // An unexpected refresh also completes, keeping this regression bounded.
      fixture.autoRefresh = true;
      expect(await old, isA<DioException>());
      expect(fixture.refreshes, isEmpty);
      expect(fixture.applied, 0);
      expect(await fixture.storage.getVisitorAccessToken(), 'access-B');
    },
  );

  test(
    'new owner does not join the retired owners refresh singleflight',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final old = fixture.request();
      await _until(() => fixture.refreshes.contains('refresh-A'));
      await fixture.login('B');
      final current = fixture.request();
      await _until(() => fixture.businessBearers.contains('Bearer access-B'));
      await _until(() => fixture.refreshes.contains('refresh-B'));
      fixture.release('B', 200);
      expect(await current, isA<Response<dynamic>>());
      fixture.release('A', 200);
      expect(await old, isA<DioException>());
      expect(await fixture.storage.getVisitorAccessToken(), 'access-B-rotated');
      expect(fixture.applied, 1);
    },
  );
}

class _Fixture {
  _Fixture();
  late SecureStorage storage;
  late Dio dio;
  final refreshes = <String>[];
  final businessBearers = <Object?>[];
  final replies = <String, Completer<ResponseBody>>{};
  Completer<void>? businessGate;
  bool autoRefresh = false;
  int applied = 0;
  static Future<_Fixture> create() async {
    FlutterSecureStorage.setMockInitialValues({});
    final fixture = _Fixture()
      ..storage = SecureStorage(const FlutterSecureStorage());
    await fixture.login('A');
    fixture.dio = fixture.createClient();
    return fixture;
  }

  Dio createClient() {
    Dio fresh() =>
        Dio(BaseOptions(baseUrl: 'https://visitor-race.example/api'))
          ..httpClientAdapter = _Adapter(respond);
    final client = fresh();
    client.interceptors.add(
      VisitorAuthInterceptor(
        storage: storage,
        baseUrl: client.options.baseUrl,
        dioFactory: fresh,
        replay: client.fetch<dynamic>,
      ),
    );
    return client;
  }

  Future<void> login(String owner) => storage.saveVisitorTokens(
    accessToken: 'access-$owner',
    refreshToken: 'refresh-$owner',
  );
  Future<Object> request() => dio
      .post<dynamic>('/visitor/confirmation', data: {'requestId': 'original'})
      .then<Object>((response) => response, onError: (Object error) => error)
      .timeout(const Duration(seconds: 3));
  Future<ResponseBody> respond(RequestOptions options) async {
    if (options.path == '/visitor/auth/refresh') {
      final token = (options.data as Map)['refreshToken'] as String;
      refreshes.add(token);
      if (autoRefresh) return _success(token.substring('refresh-'.length));
      return (replies[token] = Completer<ResponseBody>()).future;
    }
    businessBearers.add(options.headers['Authorization']);
    await businessGate?.future;
    if (options.headers['Authorization'].toString().endsWith('-rotated')) {
      applied++;
      return _json(200, {'applied': true});
    }
    return _json(401, {'code': 'UNAUTHORIZED'});
  }

  void release(String owner, int status) => replies['refresh-$owner']!.complete(
    status == 200 ? _success(owner) : _json(status, {'code': 'UNAUTHORIZED'}),
  );
  ResponseBody _success(String owner) => _json(200, {
    'accessToken': 'access-$owner-rotated',
    'refreshToken': 'refresh-$owner-rotated',
  });
  void close() {
    for (final reply in replies.values) {
      if (!reply.isCompleted) {
        reply.complete(_json(503, {'code': 'SERVICE_UNAVAILABLE'}));
      }
    }
    dio.close(force: true);
  }
}

ResponseBody _json(int status, Map<String, Object> body) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) => respond(options);
  @override
  void close({bool force = false}) {}
}

Future<void> _until(bool Function() predicate) async {
  final watch = Stopwatch()..start();
  while (!predicate()) {
    if (watch.elapsed > const Duration(seconds: 2)) {
      throw StateError('Expected owner request did not dispatch');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
