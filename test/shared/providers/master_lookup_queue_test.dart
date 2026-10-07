import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/master_lookup_queue.dart';

void main() {
  test(
    'disposed lookup queues stop old queued requests and resolve waiters',
    () async {
      final gate = Completer<void>();
      final requested = <String>[];
      final queue = MasterLookupQueue(
        batchSize: 1,
        maxConcurrent: 1,
        fetch: (ids) async {
          requested.addAll(ids);
          await gate.future;
        },
      );
      final pending = queue.load(['first', 'queued']);
      final rejected = expectLater(pending, throwsStateError);
      queue.dispose();
      await rejected;
      gate.complete();
      await Future<void>.value();
      expect(requested, ['first']);
      await expectLater(queue.load(['new']), throwsStateError);
    },
  );

  test(
    'successful lookup cache stays bounded and evicted rows can be read again',
    () async {
      final api = _LookupApi();
      final names = MasterDictionaryService(api);
      addTearDown(names.dispose);
      const count = MasterDictionaryService.maxCachedLookupRows + 101;
      await names.loadGoodsDetails(
        List.generate(count, (index) => 'goods-$index'),
      );
      expect(names.goodsInfo('goods-0'), isNull);
      expect(names.goodsInfo('goods-${count - 1}'), isNotNull);
      final calls = api.goodsBatches.length;
      await names.loadGoodsDetails(['goods-0']);
      expect(api.goodsBatches.length, calls + 1);
      expect(names.goodsInfo('goods-0')?.code, 'goods-0');
    },
  );

  test(
    '501 goods use bounded requests and overlapping detail reads share work',
    () async {
      final api = _LookupApi();
      final names = MasterDictionaryService(api);
      final ids = List.generate(501, (index) => 'goods-$index');
      await Future.wait([
        names.loadGoodsNames(ids),
        names.loadGoodsDetails(ids.reversed),
      ]);
      expect(api.goodsBatches, hasLength(6));
      expect(api.goodsBatches.every((batch) => batch.length <= 100), isTrue);
      expect(api.goodsBatches.expand((batch) => batch), hasLength(501));
      expect(api.peak, lessThanOrEqualTo(4));
      expect(names.goods('goods-500'), 'Name goods-500');
      expect(names.goodsInfo('goods-500')?.code, 'goods-500');
      await names.loadGoodsDetails(ids);
      expect(api.goodsBatches, hasLength(6));
    },
  );

  test(
    'employee lookups are bounded, deduplicated and failures remain retryable',
    () async {
      final api = _LookupApi()..failEmployeeOnce = 'employee-0';
      final names = MasterDictionaryService(api);
      final ids = List.generate(24, (index) => 'employee-$index');
      await Future.wait([
        names.loadEmployeeNames(ids),
        names.loadEmployeeNames(ids.reversed),
      ]);
      expect(api.employeeCalls, hasLength(24));
      expect(api.peak, lessThanOrEqualTo(4));
      expect(names.employee('employee-23'), 'Employee employee-23');
      await names.loadEmployeeNames(ids);
      expect(api.employeeCalls, hasLength(25));
      expect(names.employee('employee-0'), 'Employee employee-0');
    },
  );
}

class _LookupApi extends ApiClient {
  _LookupApi() : super(Dio());
  final goodsBatches = <List<String>>[];
  final employeeCalls = <String>[];
  int active = 0;
  int peak = 0;
  String? failEmployeeOnce;

  Future<void> _wait() async {
    active++;
    if (active > peak) peak = active;
    await Future<void>.delayed(const Duration(milliseconds: 1));
    active--;
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expect(path, ApiEndpoints.goodsLookup);
    final ids = (query!['ids'] as String).split(',');
    goodsBatches.add(ids);
    await _wait();
    return [
      for (final id in ids) {'id': id, 'name': 'Name $id', 'code': id},
    ];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final id = path.split('/').last;
    employeeCalls.add(id);
    await _wait();
    if (id == failEmployeeOnce) {
      failEmployeeOnce = null;
      throw StateError('temporary lookup failure');
    }
    return {'id': id, 'fullName': 'Employee $id'};
  }
}
