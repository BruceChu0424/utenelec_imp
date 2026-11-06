import 'package:uten_imp/shared/paging/scoped_paged_read.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_mutation_reload_safety.dart';
import 'package:uten_imp/core/network/request_reload_semantics.dart';
import 'package:uten_imp/core/network/interceptors/safe_request_retry_interceptor.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';

void main() {
  for (final authenticated in [false, true]) {
    test(
      'a disposed owner callback retires reads without throwing from the cancellation timer: $authenticated',
      () async {
        var disposed = false;
        bool alive() {
          if (disposed) throw StateError('provider disposed');
          return true;
        }

        final adapter = _Adapter();
        final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
          ..httpClientAdapter = adapter;
        final api = ApiClient(dio);
        final scope = authenticated
            ? await AuthenticatedRequestScope.capture(
                baseUrl: dio.options.baseUrl,
                storage: null,
                isCurrent: alive,
              )
            : null;
        final read = scope != null
            ? scope.run(() => api.get('/details/owned'))
            : PagedReadIntent.scopedRead(
                alive,
                () => api.get('/details/owned'),
              );
        final rejected = expectLater(
          read,
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              authenticated ? 'SESSION_CHANGED' : 'REQUEST_STALE',
            ),
          ),
        );
        await adapter.ready(1);
        disposed = true;
        await rejected;
        expect(adapter.cancelled, [true]);
        expect(adapter.requests, hasLength(1));
        adapter.respond(0, '{}');
        dio.close(force: true);
      },
    );
  }

  test(
    'an authenticated operation owner retires detail reads without a pager',
    () async {
      var current = true;
      final adapter = _Adapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
        ..httpClientAdapter = adapter;
      final api = ApiClient(dio);
      final scope = await AuthenticatedRequestScope.capture(
        baseUrl: dio.options.baseUrl,
        storage: null,
        isCurrent: () => current,
      );
      final read = scope.run(() => api.get('/details/owned'));
      final rejected = expectLater(
        read,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'SESSION_CHANGED'),
        ),
      );
      await adapter.ready(1);
      current = false;
      await rejected;
      expect(adapter.cancelled, [true]);
      expect(adapter.requests, hasLength(1));
      adapter.respond(0, '{}');
      dio.close(force: true);
    },
  );

  test(
    'body-carried search reads share read safety, cancellation and exact retry policy',
    () async {
      final adapter = _Adapter();
      final safety = ApiMutationReloadSafety();
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
        ..httpClientAdapter = adapter;
      final api = ApiClient(dio, reloadSafety: safety);
      const paths = [
        '/master/clients/search',
        '/master/clients/search-context',
        '/master/suppliers/search',
        '/master/suppliers/search-context',
        '/master/accounts/search',
        '/business-references/clients/search',
        '/business-references/clients/search-context',
        '/business-references/suppliers/search',
        '/business-references/suppliers/search-context',
        '/finance/reports/ar-ap/overview/search',
        '/quality/pending-disposals/query',
        '/production/daily-reports/draft-claims/query',
        '/security/blacklist/search',
        '/master/clients/access-candidates/query',
        '/admin/data-handovers/candidates/query',
      ];
      var index = 0;
      for (final prefix in ['', '/api']) {
        for (final path in paths) {
          final full = '$prefix$path';
          expect(isReadOnlyPost(full), true);
          expect(
            isBusinessWrite(RequestOptions(path: full, method: 'POST')),
            false,
          );
          for (final suffix in ['/save', '/confirm', '/export']) {
            expect(isReadOnlyPost('$full$suffix'), false);
            expect(
              isBusinessWrite(
                RequestOptions(path: '$full$suffix', method: 'POST'),
              ),
              true,
            );
          }
          final options = RequestOptions(path: full, method: 'POST');
          expect(
            shouldRetrySafeRequest(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
              ),
            ),
            true,
          );
          expect(
            shouldRetrySafeRequest(
              DioException(
                requestOptions: options,
                type: DioExceptionType.receiveTimeout,
              ),
            ),
            false,
          );
          final read = api.post(full, body: {'keyword': '单字'});
          expect(safety.pendingReadCount, 1);
          expect(safety.pendingCount, 0);
          await adapter.ready(index + 1);
          adapter.respond(index++, '{}');
          await read;
        }
      }
      expect(safety.pendingReadCount, 0);
      expect(safety.hasUncertainCommit, false);
      dio.close(force: true);
    },
  );

  test(
    'retiring a search aborts its transport, keeps read safety and sends no replacement',
    () async {
      final adapter = _Adapter();
      final safety = ApiMutationReloadSafety();
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
        ..httpClientAdapter = adapter;
      final api = ApiClient(dio, reloadSafety: safety);
      var current = true;
      final read = PagedReadIntent.scopedRead(
        () => current,
        () => api.get('/items', query: {'keyword': '张'}),
      );
      final rejected = expectLater(
        read,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'REQUEST_STALE'),
        ),
      );
      await adapter.ready(1);
      current = false;
      await rejected;
      expect(adapter.cancelled, [true]);
      expect(adapter.requests, hasLength(1));
      expect(safety.pendingReadCount, 0);
      expect(safety.pendingCount, 0);
      adapter.respond(0, '{}');
      dio.close(force: true);
    },
  );

  test(
    'complete-query consumers share one transport and retiring its owner cancels only that read',
    () async {
      final adapter = _Adapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
        ..httpClientAdapter = adapter;
      final api = ApiClient(dio);
      final cache = ScopedPagedRead<String>();
      addTearDown(cache.dispose);
      Future<PagedResult<String>> fetch() async {
        await api.get('/items', query: {'keyword': '旧'});
        return const PagedResult(
          items: ['old'],
          page: 1,
          size: 20,
          total: 1,
          totalPages: 1,
        );
      }

      final a = cache.read(
        1,
        scope: 'Q',
        fetchPage: (_) => fetch(),
        isCurrent: () => true,
        useCache: true,
      );
      final b = cache.read(
        1,
        scope: 'Q',
        fetchPage: (_) => fetch(),
        isCurrent: () => true,
        useCache: true,
      );
      expect(identical(a, b), true);
      final rejectedA = expectLater(
        a,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'REQUEST_STALE'),
        ),
      );
      final rejectedB = expectLater(b, throwsA(isA<ApiException>()));
      await adapter.ready(1);
      cache.invalidate();
      await Future.wait([rejectedA, rejectedB]);
      expect(adapter.requests, hasLength(1));
      expect(adapter.cancelled, [true]);
      final current = await cache.read(
        1,
        scope: 'Q',
        isCurrent: () => true,
        fetchPage: (_) async => const PagedResult<String>(
          items: ['new'],
          page: 1,
          size: 100,
          total: 1,
          totalPages: 1,
        ),
      );
      expect(current.items, ['new']);
      adapter.respond(0, '{}');
      dio.close(force: true);
    },
  );

  test(
    'a retired read predicate never cancels or retries a business command',
    () async {
      final adapter = _Adapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
        ..httpClientAdapter = adapter;
      final api = ApiClient(dio);
      final command = PagedReadIntent.scopedRead(
        () => false,
        () => api.post('/sales/orders', body: {'raw': '保留原始输入'}),
      );
      await adapter.ready(1);
      expect(adapter.requests.single.cancelToken, isNull);
      adapter.respond(0, '{"id":"new-order"}');
      expect((await command)['id'], 'new-order');
      expect(adapter.requests, hasLength(1));
      dio.close(force: true);
    },
  );

  test(
    'all large-scope reads are exact pure reads, neighboring commands remain writes',
    () {
      for (final prefix in ['', '/api']) {
        for (final base in ['/master/goods', '/business-references/goods']) {
          for (final action in [
            'search',
            'search-category-ids',
            'facets',
            'facet-values',
          ]) {
            final path = '$prefix$base/$action';
            expect(isReadOnlyPost(path), true);
            expect(
              isBusinessWrite(RequestOptions(path: path, method: 'POST')),
              false,
            );
            expect(
              isBusinessWrite(
                RequestOptions(path: '$path/save', method: 'POST'),
              ),
              true,
            );
            expect(isReadOnlyPost('$path/save'), false);
          }
          expect(
            isBusinessWrite(
              RequestOptions(path: '$prefix$base', method: 'POST'),
            ),
            true,
          );
        }
      }
    },
  );

  test(
    'JSON-body goods reads inherit cancellation; string arrays stay strictly typed',
    () async {
      final adapter = _Adapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
        ..httpClientAdapter = adapter;
      final api = ApiClient(dio);
      var current = true;
      final read = PagedReadIntent.scopedRead(
        () => current,
        () => api.postStringList(
          '/master/goods/search-category-ids',
          body: {
            'filter': {'keyword': '螺'},
          },
        ),
      );
      final rejected = expectLater(
        read,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'REQUEST_STALE'),
        ),
      );
      await adapter.ready(1);
      current = false;
      await rejected;
      expect(adapter.cancelled, [true]);
      adapter.respond(0, '[]');
      final invalid = api.postStringList(
        '/master/goods/search-category-ids',
        body: {'filter': <String, dynamic>{}},
      );
      final invalidResult = expectLater(invalid, throwsFormatException);
      await adapter.ready(2);
      adapter.respond(1, '["valid", 1]');
      await invalidResult;
      await expectLater(
        api.postStringList('/master/goods/save', body: {}),
        throwsArgumentError,
      );
      expect(adapter.requests, hasLength(2));
      dio.close(force: true);
    },
  );
}

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final pending = <Completer<ResponseBody>>[];
  final cancelled = <bool>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final index = pending.length;
    requests.add(options);
    final result = Completer<ResponseBody>();
    pending.add(result);
    cancelled.add(false);
    cancelFuture?.then((_) => cancelled[index] = true);
    return result.future;
  }

  Future<void> ready(int count) async {
    for (var i = 0; requests.length < count && i < 100; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(requests.length, count);
  }

  void respond(int index, String value) => pending[index].complete(
    ResponseBody.fromBytes(
      utf8.encode(value),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    ),
  );
  @override
  void close({bool force = false}) {}
}
