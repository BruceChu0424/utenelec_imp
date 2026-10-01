import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';

class _Adapter implements HttpClientAdapter {
  int status = 200;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    '{}',
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'readonly POSTs do not trigger business refresh, actual drafts and field writes do',
    () async {
      final writes = <String>[];
      final adapter = _Adapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://revision.example'))
        ..httpClientAdapter = adapter
        ..interceptors.add(
          DataWriteRevisionInterceptor(
            (options) => writes.add(options.uri.path),
          ),
        );
      addTearDown(dio.close);
      await dio.post<dynamic>(
        '/platform-columns/production_plan_item/values:batch',
      );
      await dio.post<dynamic>(
        '/production/material-analyses/a/issue-plans/preview',
      );
      await dio.post<dynamic>(
        '/production/material-analyses/a/aggregate-orders/preview',
      );
      await dio.post<dynamic>('/master/goods/cost-sheets/preview');
      await dio.post<dynamic>(
        '/procurement/inspection/PURCHASE/receipt-1/decide-batch/receipt',
      );
      expect(writes, isEmpty);
      await dio.post<dynamic>('/production/material-analyses/preview');
      await dio.put<dynamic>(
        '/platform-columns/production_plan_item/values/row-1',
      );
      await dio.post<dynamic>('/other-domain/preview');
      await dio.post<dynamic>('/other-domain/resolve-batch');
      await dio.post<dynamic>('/finance/asset-posting-runs/preview');
      await dio.post<dynamic>(
        '/procurement/inspection/PURCHASE/receipt-1/decide-batch',
      );
      expect(writes, [
        '/production/material-analyses/preview',
        '/platform-columns/production_plan_item/values/row-1',
        '/other-domain/preview',
        '/other-domain/resolve-batch',
        '/finance/asset-posting-runs/preview',
        '/procurement/inspection/PURCHASE/receipt-1/decide-batch',
      ]);
      adapter.status = 409;
      await expectLater(
        dio.post<dynamic>('/production/material-analyses/preview'),
        throwsA(isA<DioException>()),
      );
      expect(
        writes,
        hasLength(6),
        reason: 'an unsuccessful command never reports a data write',
      );
    },
  );
}
