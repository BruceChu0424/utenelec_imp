import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/print/complete_print_snapshot.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  Future<PagedResult<int>> page(
    int number,
    int requested, {
    int total = 601,
    int actualSize = 100,
  }) async {
    final start = (number - 1) * actualSize;
    return PagedResult(
      items: List.generate(
        (total - start).clamp(0, actualSize),
        (i) => start + i,
      ),
      page: number,
      size: actualSize,
      total: total,
      totalPages: (total + actualSize - 1) ~/ actualSize,
    );
  }

  test(
    'complete printing follows all actual server pages rather than trusting an oversized requested page',
    () async {
      final calls = <int>[];
      final table = await loadCompletePrintSnapshot<int>(
        loadPage: (number, size) {
          calls.add(number);
          expect(size, 100);
          return page(number, size, actualSize: 50);
        },
        idOf: (row) => 'id-$row',
        headers: ['原始姓名', '精确金额'],
        columnKeys: ['name', 'amount'],
        cellsOf: (row) => ['姓名龘$row', '000000000000001.000000000000000001'],
        factsOf: (row) => {'amount': '1.000000000000000001'},
        isCurrent: () => true,
      );
      expect(calls, hasLength(13));
      expect(table.rows, hasLength(601));
      expect(table.rowIds!.last, 'id-600');
      expect(table.rows.last, ['姓名龘600', '000000000000001.000000000000000001']);
      expect(table.factValues!.last['amount'], '1.000000000000000001');
    },
  );

  test(
    'empty complete result retains its schema and no fabricated rows',
    () async {
      final table = await loadCompletePrintSnapshot<int>(
        loadPage: (p, s) => page(p, s, total: 0),
        idOf: (row) => '$row',
        headers: ['名称'],
        columnKeys: ['name'],
        cellsOf: (row) => ['$row'],
        isCurrent: () => true,
      );
      expect(table.rows, isEmpty);
      expect(table.headers, ['名称']);
    },
  );

  for (final failure in [
    'wrong-page',
    'empty-continuation',
    'changed-total',
    'network',
  ]) {
    test('$failure returns no partial paper', () async {
      var calls = 0;
      await expectLater(
        loadCompletePrintSnapshot<int>(
          loadPage: (p, s) async {
            calls++;
            if (p == 1) {
              return page(p, s);
            }
            if (failure == 'network') {
              throw ApiException('FIXTURE_FAILURE', '合成失败');
            }
            if (failure == 'changed-total') return page(p, s, total: 602);
            if (failure == 'wrong-page') return page(1, s);
            return PagedResult(
              items: <int>[],
              page: p,
              size: s,
              total: 601,
              totalPages: 7,
            );
          },
          idOf: (row) => '$row',
          headers: ['名称'],
          columnKeys: ['name'],
          cellsOf: (row) => ['$row'],
          isCurrent: () => true,
        ),
        throwsA(isA<ApiException>()),
      );
      expect(calls, 2);
    });
  }

  test(
    'retired A-to-B-to-A epochs cannot publish a late page or formatted paper',
    () async {
      var epoch = 0;
      final captured = epoch;
      await expectLater(
        loadCompletePrintSnapshot<int>(
          loadPage: (p, s) async {
            final result = await page(p, s);
            if (p == 2) {
              epoch++;
              epoch++;
            }
            return result;
          },
          idOf: (row) => '$row',
          headers: ['名称'],
          columnKeys: ['name'],
          cellsOf: (row) => ['$row'],
          isCurrent: () => epoch == captured,
        ),
        throwsA(isA<UiWorkCancelled>()),
      );
    },
  );

  test(
    'formatting a large complete table yields and can retire without publishing half a result',
    () async {
      var ticks = 0;
      var current = true;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      addTearDown(timer.cancel);
      final table = await loadCompletePrintSnapshot<int>(
        loadPage: (p, s) => page(p, s, total: 10001),
        idOf: (row) => '$row',
        headers: ['名称'],
        columnKeys: ['name'],
        cellsOf: (row) => ['值$row'],
        isCurrent: () => current,
        budget: UiWorkBudget(maxItems: 16, slice: const Duration(hours: 1)),
      );
      expect(table.rows, hasLength(10001));
      expect(ticks, greaterThan(1));
      await expectLater(
        loadCompletePrintSnapshot<int>(
          loadPage: (p, s) => page(p, s, total: 3),
          idOf: (row) => '$row',
          headers: ['名称'],
          columnKeys: ['name'],
          cellsOf: (row) {
            if (row == 1) current = false;
            return ['值$row'];
          },
          isCurrent: () => current,
        ),
        throwsA(isA<UiWorkCancelled>()),
      );
    },
  );
}
