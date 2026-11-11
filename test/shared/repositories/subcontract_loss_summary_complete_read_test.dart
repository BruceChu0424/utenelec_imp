import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/repositories/subcontract_loss_summary_loader.dart';

class _Summaries extends ApiClient {
  _Summaries() : super(Dio());
  final queries = <Map<String, dynamic>>[];
  final paths = <String>[];
  Object? tailFailure;
  bool changeRevision = false;
  void Function()? afterFirst;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    paths.add(path);
    queries.add(Map<String, dynamic>.from(query ?? const {}));
    final page = query!['page'] as int;
    if (page == 2 && tailFailure != null) throw tailFailure!;
    final first = (page - 1) * 1000;
    final end = (first + 1000).clamp(0, 1001);
    final value = <String, dynamic>{
      'items': [
        for (var n = first; n < end; n++)
          {
            'goodsId': 'goods-$n',
            'goodsName': '损耗货品$n',
            'settledLineCount': 1,
            'orderedQtyExact': '98765432109876543210.1234567890123456789',
            'lossQtyExact': '0.0000000000000000001',
          },
      ],
      'page': page,
      'size': 1000,
      'total': 1001,
      'totalPages': 2,
      'scope': 'all',
      'readScopeVersion': 'authority',
      'readSnapshotRevision': page == 2 && changeRevision ? 'new' : 'original',
      'readDataVersion': 'dataset-revision',
      if (page == 1)
        'summary': {
          'supplierId': 'supplier-1',
          'settledLineCount': 1001,
          'acceptedLossCount': 1000,
          'orderedQtyExact': '999999999999999999999.1234567890123456789',
          'lossQtyExact': '0.000000000000000001',
          'lossPctExact': '0.0000000000000000000001',
          'maxLossPctExact': '0.123456789012345678901',
          'lastLossAt': '2026-11-01T00:00:00Z',
          'byGoods': const <Map<String, dynamic>>[],
          'recentCases': const <Map<String, dynamic>>[],
        },
    };
    if (page == 1) afterFirst?.call();
    return value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'all1001 goods and exact weighted header survive two bounded batches',
    () async {
      final api = _Summaries();
      final result = await loadSubcontractSupplierLossSummary(
        api,
        'supplier-1',
      );
      expect(result.byGoods, hasLength(1001));
      expect(result.byGoods.last.goodsId, 'goods-1000');
      expect(
        result.byGoods.last.orderedQtyValue,
        '98765432109876543210.1234567890123456789',
      );
      expect(
        result.orderedQtyValue,
        '999999999999999999999.1234567890123456789',
      );
      expect(result.lossPctValue, '0.0000000000000000000001');
      expect(result.acceptedLossCount, 1000);
      expect(result.lastLossAt, '2026-11-01T00:00:00Z');
      expect(api.queries.map((q) => q['page']), [1, 2]);
      expect(api.queries.last['readSnapshotRevision'], 'original');
      expect(api.paths.toSet(), {
        '$subcontractSupplierLossSummaryPath/goods/summaries',
      });
    },
  );
  test('failed or revoked tail never returns a first1000 prefix', () async {
    for (final error in [
      ApiException('NETWORK', 'owned fixture offline'),
      ApiException('FORBIDDEN', 'owned fixture revoked', httpStatus: 403),
    ]) {
      final api = _Summaries()..tailFailure = error;
      // 完整读取漏斗（read_failure_diagnostics）会重建异常并追加匿名关联号，
      // 实例身份不再保持；契约断言改为同 code + 原消息为前缀，前缀结果仍被拒。
      await expectLater(
        loadSubcontractSupplierLossSummary(api, 'supplier-1'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', error.code)
              .having((e) => e.message, 'message', startsWith(error.message)),
        ),
      );
      expect(api.queries.map((q) => q['page']), [1, 2]);
    }
  });
  test('same-count changed snapshot cannot publish mixed goods', () async {
    final api = _Summaries()..changeRevision = true;
    await expectLater(
      loadSubcontractSupplierLossSummary(api, 'supplier-1'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'SNAPSHOT_CHANGED'),
      ),
    );
  });
  test(
    'retired current supplier stops before another bounded request',
    () async {
      var current = true;
      final api = _Summaries()..afterFirst = () => current = false;
      await expectLater(
        PagedReadIntent.scopedRead(
          () => current,
          () => loadSubcontractSupplierLossSummary(api, 'supplier-1'),
        ),
        throwsA(
          predicate(
            (e) =>
                e is UiWorkCancelled ||
                e is ApiException && e.code == 'SESSION_CHANGED',
          ),
        ),
      );
      expect(api.queries, hasLength(1));
    },
  );
}
