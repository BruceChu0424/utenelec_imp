import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_mutation_reload_safety.dart';
import 'package:uten_imp/core/network/interceptors/safe_request_retry_interceptor.dart';
import 'package:uten_imp/core/network/responsive_json_decoder.dart';
import 'package:uten_imp/core/network/responsive_json_transformer.dart';
import 'package:uten_imp/core/network/summary_stream_contract.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/account_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/color_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/currency_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/unit_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/features/basic_data/models/account_node.dart';
import 'package:uten_imp/features/basic_data/models/color_node.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/models/settlement_method_admin.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  final calls = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _page(int page, int total) => {
  'page': page,
  'size': 100,
  'total': total,
  'totalPages': (total + 99) ~/ 100,
  'readScopeVersion': 'a' * 64,
  'readSnapshotRevision': 'b' * 64,
  'readDataVersion': 'c' * 64,
  'items': [
    for (var i = (page - 1) * 100; i < page * 100 && i < total; i++)
      {
        'id': 'goods-$i',
        'name': '原文货品$i',
        'priceDisplayText': '123.456789012345',
      },
  ],
};

List<Map<String, dynamic>> _frames(int total) => [
  for (var page = 1; page <= ((total + 99) ~/ 100).clamp(1, total + 1); page++)
    {'type': 'page', 'value': _page(page, total)},
  {
    'type': 'complete',
    'total': total,
    'readScopeVersion': 'a' * 64,
    'readSnapshotRevision': 'b' * 64,
    'readDataVersion': 'c' * 64,
  },
];

Uint8List _bytes(Map<String, dynamic> frame) =>
    Uint8List.fromList(utf8.encode('${jsonEncode(frame)}\n'));

ResponseBody _body(Stream<Uint8List> stream) => ResponseBody(
  stream,
  200,
  headers: {
    Headers.contentTypeHeader: ['$summaryStreamContentType;charset=UTF-8'],
  },
);

({ApiClient api, _Adapter adapter, ApiMutationReloadSafety safety}) _client(
  ResponseBody Function(RequestOptions) response, {
  Duration receiveTimeout = const Duration(seconds: 45),
}) {
  final adapter = _Adapter(response);
  final decoder = ResponsiveJsonDecoder();
  final dio =
      Dio(
          BaseOptions(
            baseUrl: 'https://fixture.test/api',
            receiveTimeout: receiveTimeout,
          ),
        )
        ..httpClientAdapter = adapter
        ..transformer = ResponsiveJsonTransformer(decoder);
  final safety = ApiMutationReloadSafety();
  dio.interceptors.add(SafeRequestRetryInterceptor(dio));
  addTearDown(() {
    decoder.dispose();
    dio.close(force: true);
  });
  return (
    api: ApiClient(dio, reloadSafety: safety),
    adapter: adapter,
    safety: safety,
  );
}

Future<void> _until(bool Function() predicate) async {
  final deadline = Stopwatch()..start();
  while (!predicate()) {
    if (deadline.elapsed > const Duration(seconds: 3)) {
      fail('Expected stream state was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  final flatReaders =
      <String, Future<PagedResult<dynamic>> Function(ApiClient)>{
        '/master/colors/summaries': (api) =>
            DioColorRepository(api).completeList(
              keyword: ' 原查询 ',
              filters: _filters,
              sort: 'name',
              order: 'desc',
            ),
        '/master/units/summaries': (api) => DioUnitRepository(api).completeList(
          keyword: ' 原查询 ',
          filters: _filters,
          sort: 'name',
          order: 'desc',
        ),
        '/master/currencies/summaries': (api) =>
            DioCurrencyRepository(api).completeList(
              keyword: ' 原查询 ',
              filters: _filters,
              sort: 'name',
              order: 'desc',
            ),
        '/master/accounts/summaries': (api) =>
            DioAccountRepository(api).completeList(
              keyword: ' 原查询 ',
              filters: _filters,
              sort: 'name',
              order: 'desc',
            ),
        '/master/reference-methods/settlement-admin/summaries': (api) =>
            DioReferenceMethodRepository(api).completeList(
              keyword: ' 原查询 ',
              filters: _filters,
              sort: 'name',
              order: 'desc',
            ),
      };
  for (final entry in flatReaders.entries) {
    test(
      'flat ${entry.key} retains query and typed tail through one HTTP',
      () async {
        final frames = _frames(101);
        for (final frame in frames.where((f) => f['type'] == 'page')) {
          for (final row in (frame['value'] as Map)['items'] as List) {
            (row as Map).addAll(<String, String>{
              'exchangeRateText': '1.234567890123456789',
              'balanceCurrentText': '90071992547409.1234567890123456789',
              'remark': '原始备注',
            });
          }
        }
        final client = _client(
          (_) => _body(Stream.fromIterable(frames.map(_bytes))),
        );
        final result = await entry.value(client.api);
        expect(result.items, hasLength(101));
        final last = result.items.last as Object;
        expect(_identity(last).$1, 'goods-100');
        expect(_identity(last).$2, '原文货品100');
        if (last is CurrencyListItem) {
          expect(last.exchangeRateText, '1.234567890123456789');
        }
        if (last is AccountListItem) {
          expect(last.balanceCurrentText, '90071992547409.1234567890123456789');
        }
        expect(client.adapter.calls, hasLength(1));
        final request = client.adapter.calls.single;
        final body = request.data as Map<String, dynamic>;
        expect(request.path, entry.key);
        expect(body['filter'], {
          'keyword': '原查询',
          'status': '使用',
          'nullFields': ['remark'],
          'columnSearch': {'name': '名称原词'},
        });
        expect(body['sort'], 'name');
        expect(body['order'], 'desc');
        expect(body['size'], 100);
      },
    );
  }
  test(
    '10001 complete goods use one HTTP and no hidden per-page requests',
    () async {
      final client = _client(
        (_) => _body(Stream.fromIterable(_frames(10001).map(_bytes))),
      );
      final result = await DioGoodsRepository(client.api).completeList(
        'category-original',
        keyword: '原查询',
        sort: 'code',
        order: 'desc',
      );
      expect(result.items, hasLength(10001));
      expect(result.items.last.id, 'goods-10000');
      expect(result.items.last.priceDisplayText, '123.456789012345');
      expect(client.adapter.calls, hasLength(1));
      final call = client.adapter.calls.single;
      expect(call.queryParameters, {'complete': true});
      expect(call.headers['Accept'], summaryStreamContentType);
      expect(call.extra[summaryStreamRequestKey], isTrue);
      expect(call.extra[safeRequestRetryDisabledKey], isTrue);
      expect(call.receiveTimeout, const Duration(seconds: 45));
      final body = call.data as Map<String, dynamic>;
      final filter = body['filter'] as Map<String, dynamic>;
      expect(filter['categoryId'], 'category-original');
      expect(filter['keyword'], '原查询');
      expect(body['size'], 100);
      expect(body['order'], 'desc');
      expect(client.safety.pendingReadCount, 0);
      expect(client.safety.pendingCount, 0);
      expect(client.safety.hasUncertainCommit, isFalse);
    },
  );

  test(
    'read/update guard remains held through terminal frame and EOF',
    () async {
      final source = StreamController<Uint8List>();
      final client = _client((_) => _body(source.stream));
      final pending = DioGoodsRepository(client.api).completeList(null);
      await _until(() => client.adapter.calls.isNotEmpty);
      final frames = _frames(1);
      source.add(_bytes(frames.first));
      await Future<void>.delayed(Duration.zero);
      expect(client.safety.pendingReadCount, 1);
      source.add(_bytes(frames.last));
      await Future<void>.delayed(Duration.zero);
      expect(client.safety.pendingReadCount, 1);
      await source.close();
      expect((await pending).items, hasLength(1));
      expect(client.safety.pendingReadCount, 0);
    },
  );

  test(
    'retiring owner aborts a stalled body and cannot publish old rows',
    () async {
      final source = StreamController<Uint8List>();
      addTearDown(() => source.close());
      final client = _client((_) => _body(source.stream));
      var current = true;
      final pending = PagedReadIntent.scopedRead(
        () => current,
        () => DioGoodsRepository(client.api).completeList(null),
      );
      final rejection = expectLater(
        pending,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'SESSION_CHANGED'),
        ),
      );
      await _until(() => client.adapter.calls.isNotEmpty);
      source.add(_bytes(_frames(101).first));
      current = false;
      await _until(() => client.adapter.calls.single.cancelToken!.isCancelled);
      // The adapter cancellation must finish even if the server never sends a tail.
      await rejection.timeout(const Duration(seconds: 2));
      expect(client.safety.pendingReadCount, 0);
      expect(client.safety.hasUncertainCommit, isFalse);
    },
  );

  test(
    'stream keeps original receive timeout and never retries partial body',
    () async {
      final source = StreamController<Uint8List>();
      addTearDown(() => source.close());
      final client = _client(
        (_) => _body(source.stream),
        receiveTimeout: const Duration(milliseconds: 30),
      );
      await expectLater(
        DioGoodsRepository(client.api).completeList(null),
        throwsA(isA<NetworkTimeoutException>()),
      );
      expect(client.adapter.calls, hasLength(1));
      expect(client.safety.pendingReadCount, 0);
    },
  );

  test(
    'HTTP refusal JSON retains permission code and no uncertain write',
    () async {
      final client = _client(
        (_) => ResponseBody.fromString(
          '{"code":"READ_SCOPE_CHANGED","message":"权限已变化"}',
          403,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      await expectLater(
        DioGoodsRepository(client.api).completeList(null),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'READ_SCOPE_CHANGED',
          ),
        ),
      );
      expect(client.adapter.calls, hasLength(1));
      expect(client.safety.hasUncertainCommit, isFalse);
    },
  );

  test(
    'unsupported old server cannot trigger a second paged request',
    () async {
      final client = _client(
        (_) => ResponseBody.fromString(
          jsonEncode(_page(1, 201)),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      await expectLater(
        DioGoodsRepository(client.api).completeList(null),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'INCOMPLETE_READ_PROTOCOL',
          ),
        ),
      );
      expect(client.adapter.calls, hasLength(1));
    },
  );
}

const _filters = <String, String?>{
  'status': '使用',
  'remark': '__null__',
  'search.name': '名称原词',
};

(String, String?) _identity(Object row) => switch (row) {
  ColorListItem(:final id, :final name) => (id, name),
  UnitListItem(:final id, :final name) => (id, name),
  CurrencyListItem(:final id, :final name) => (id, name),
  AccountListItem(:final id, :final name) => (id, name),
  SettlementMethodAdminItem(:final id, :final name) => (id, name),
  _ => throw StateError('Unexpected typed summary row'),
};
