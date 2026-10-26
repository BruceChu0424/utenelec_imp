import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/core/network/interceptors/read_scope_revision_interceptor.dart';

class _Adapter implements HttpClientAdapter {
  final replies = <String, Completer<ResponseBody>>{};
  final started = <String, Completer<void>>{};
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) {
    final id = options.queryParameters['request'] as String;
    started[id]!.complete();
    return replies[id]!.future;
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const first = AuthenticatedRequestIdentity(
    baseUrl: 'https://scope.fixture/api',
    lineage: 'A',
    intent: 1,
    impersonationLineage: null,
  );
  const second = AuthenticatedRequestIdentity(
    baseUrl: 'https://scope.fixture/api',
    lineage: 'B',
    intent: 2,
    impersonationLineage: null,
  );
  late Dio dio;
  late _Adapter adapter;
  late int revision;
  late AuthenticatedRequestIdentity actor;
  setUp(() {
    actor = first;
    revision = 0;
    adapter = _Adapter();
    dio = Dio(BaseOptions(baseUrl: 'https://scope.fixture/api'))
      ..httpClientAdapter = adapter;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.extra['subject'] = actor;
          handler.next(options);
        },
      ),
    );
    dio.interceptors.add(
      ReadScopeRevisionInterceptor(
        currentRevision: () => revision,
        retire: () => revision++,
        identity: (options) =>
            options.extra['subject'] as AuthenticatedRequestIdentity?,
        isCurrent: (options) async => options.extra['subject'] == actor,
      ),
    );
  });
  tearDown(() => dio.close(force: true));
  Future<Response<dynamic>> request(
    String id, {
    String path = '/sales/reports/ORDER/detail',
  }) {
    adapter.replies[id] = Completer<ResponseBody>();
    adapter.started[id] = Completer<void>();
    return dio.get<dynamic>(path, queryParameters: {'request': id});
  }

  void reply(String id, String version, {int status = 200, String? domain}) =>
      adapter.replies[id]!.complete(
        ResponseBody.fromString(
          jsonEncode(
            status == 200
                ? {'rows': <Object?>[], 'readScopeVersion': version}
                : {'code': 'READ_SCOPE_CHANGED', 'message': '范围变更'},
          ),
          status,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
            if (domain != null) 'X-Uten-Read-Scope-Domain': [domain],
          },
        ),
      );
  Future<void> sent() async {
    await Future.wait(adapter.started.values.map((start) => start.future));
  }

  test(
    'same-role scope change retires derived reads once and old replies cannot roll it back',
    () async {
      final initial = request('initial');
      await sent();
      reply('initial', 'A');
      await initial;
      final old = request('old');
      final fresh = request('fresh');
      await sent();
      final freshCheck = expectLater(fresh, throwsA(isA<DioException>()));
      reply('fresh', 'B');
      await freshCheck;
      expect(revision, 1);
      final oldCheck = expectLater(old, throwsA(isA<DioException>()));
      reply('old', 'A');
      await oldCheck;
      expect(revision, 1);
      final current = request('current');
      await sent();
      reply('current', 'B');
      await current;
      expect(revision, 1);
    },
  );
  test(
    'native profiles and business modes do not retire one another, but a real same-profile change does',
    () async {
      const path = '/warehouse/quality-results/facets';
      for (final entry in [('browse', 'A'), ('task', 'T')]) {
        final pending = request(entry.$1, path: path);
        await sent();
        reply(entry.$1, entry.$2, domain: 'native_warehouse_tasks:${entry.$1}');
        await pending;
      }
      expect(revision, 0);
      final changed = request('changed', path: path);
      await sent();
      final check = expectLater(changed, throwsA(isA<DioException>()));
      reply('changed', 'B', domain: 'native_warehouse_tasks:browse');
      await check;
      expect(revision, 1);
    },
  );
  test(
    'an old proof reply cannot repopulate a retired reader even when its profile was first observed later',
    () async {
      final late = request('late', path: '/production/workshop-tasks/facets');
      await sent();
      revision++;
      final check = expectLater(late, throwsA(isA<DioException>()));
      reply('late', 'old', domain: 'native_workshop_tasks:browse');
      await check;
      expect(revision, 1);
    },
  );
  test('late old-account refusals never retire the next reader', () async {
    final old = request('old');
    await sent();
    actor = second;
    final check = expectLater(old, throwsA(isA<DioException>()));
    reply('old', 'A', status: 403);
    await check;
    expect(revision, 0);
  });
  test(
    'parallel scope refusals share one retirement without logging out',
    () async {
      final a = request('a'), b = request('b');
      await sent();
      final checks = Future.wait([
        expectLater(a, throwsA(isA<DioException>())),
        expectLater(b, throwsA(isA<DioException>())),
      ]);
      reply('a', 'B', status: 403);
      reply('b', 'B', status: 403);
      await checks;
      expect(revision, 1);
      expect(actor, first);
    },
  );
  test(
    'all master page families retire their old authorization before another print page is accepted',
    () async {
      for (final master in [
        'clients',
        'suppliers',
        'goods',
        'accounts',
        'currencies',
        'colors',
        'units',
        'moulds',
        'warehouses',
      ]) {
        final path = '/master/$master';
        final initial = request('$master-initial', path: path);
        await sent();
        reply('$master-initial', 'A');
        await initial;
        final changed = request('$master-changed', path: path);
        await sent();
        final check = expectLater(changed, throwsA(isA<DioException>()));
        reply('$master-changed', 'B');
        await check;
      }
      expect(revision, 9);
      expect(actor, first);
    },
  );
}
