import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/pricing/price_analysis_models.dart';
import 'package:uten_imp/shared/pricing/procurement_price_check.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';

Map<String, dynamic> item(String key, {String price = '12'}) => {
  'rowKey': key,
  'goodsId': 'goods-$key',
  'unitPrice': price,
};
PriceCheckResult result(String key, {String message = 'checked'}) =>
    PriceCheckResult({
      'rowKey': key,
      'goodsId': 'goods-$key',
      'status': 'READY',
      'severity': 'WARNING',
      'message': message,
    });

void main() {
  testWidgets(
    'editor capture and nested copying wait until the input debounce finishes',
    (tester) async {
      final calls = <List<Map<String, dynamic>>>[];
      var captures = 0;
      final rows = [
        item('a')..['source'] = {'version': 1},
      ];
      final batch = PriceCheckBatchController((items, _) async {
        calls.add(items);
        return [result('a')];
      });
      addTearDown(batch.dispose);
      void changed() => batch.updateFromRows(
        rows: () => rows,
        payloadOf: (row) {
          captures++;
          return row;
        },
        enabled: true,
      );
      changed();
      await tester.pump(const Duration(milliseconds: 200));
      rows.single['unitPrice'] = '13';
      changed();
      await tester.pump(const Duration(milliseconds: 299));
      expect(captures, 0);
      expect(calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(captures, 1);
      expect(calls.single.single['unitPrice'], '13');
      (rows.single['source'] as Map<String, int>)['version'] = 2;
      expect(calls.single.single['source'], {'version': 1});
      expect(batch.result('a'), isNotNull);
      changed();
      expect(
        batch.result('a'),
        isNull,
        reason: 'old evidence is invalid before the next capture',
      );
      batch.invalidate();
    },
  );

  test(
    'input change during sliced capture prevents all stale network reads',
    () async {
      var captures = 0;
      var requests = 0;
      final batch = PriceCheckBatchController((items, _) async {
        requests++;
        return [];
      }, delay: Duration.zero);
      addTearDown(batch.dispose);
      batch.updateFromRows(
        rows: () => List.generate(2000, (index) => index),
        payloadOf: (row) {
          captures++;
          return item('$row');
        },
        enabled: true,
      );
      final invalidated = Completer<void>();
      Timer(Duration.zero, () {
        batch.invalidate();
        invalidated.complete();
      });
      await invalidated.future;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(captures, greaterThan(0));
      expect(captures, lessThan(2000));
      expect(requests, 0);
      expect(batch.loading, isFalse);
    },
  );

  test('price checks are reads and do not invalidate business-data caches', () {
    expect(
      isBusinessWrite(
        RequestOptions(
          path: '/api/master/goods/price-analysis/check',
          method: 'POST',
        ),
      ),
      isFalse,
    );
    expect(
      isBusinessWrite(
        RequestOptions(path: '/api/master/goods/cost-sheets', method: 'POST'),
      ),
      isTrue,
    );
  });
  testWidgets('edits debounce into one bounded batch and freeze operands', (
    tester,
  ) async {
    final calls = <List<Map<String, dynamic>>>[];
    final batch = PriceCheckBatchController((items, cancelToken) async {
      calls.add(items);
      return [result('a')];
    });
    addTearDown(batch.dispose);
    final input = item('a');
    batch.update([input], enabled: true);
    await tester.pump(const Duration(milliseconds: 200));
    input['unitPrice'] = '13';
    batch.update([input, item('b')], enabled: true);
    await tester.pump(const Duration(milliseconds: 299));
    expect(calls, isEmpty);
    input['unitPrice'] = '999';
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls.single.first['unitPrice'], '13');
    expect(calls.single, hasLength(2));
    expect(batch.result('a')!.warning, isTrue);
    expect(batch.result('b')!.text('status'), 'UNAVAILABLE');
  });

  testWidgets('late response from input A cannot revive after A-B-A', (
    tester,
  ) async {
    final pending = <Completer<List<PriceCheckResult>>>[];
    final tokens = <CancelToken>[];
    final batch = PriceCheckBatchController((items, cancelToken) {
      tokens.add(cancelToken);
      final c = Completer<List<PriceCheckResult>>();
      pending.add(c);
      return c.future;
    });
    addTearDown(batch.dispose);
    batch.update([item('a')], enabled: true);
    await tester.pump(const Duration(milliseconds: 300));
    batch.update([item('a', price: '14')], enabled: true);
    expect(tokens.first.isCancelled, isTrue);
    batch.update([item('a')], enabled: true);
    pending.first.complete([result('a', message: 'old')]);
    await tester.pump();
    expect(batch.result('a'), isNull);
    await tester.pump(const Duration(milliseconds: 300));
    pending.last.complete([result('a', message: 'fresh')]);
    await tester.pump();
    expect(batch.result('a')!.text('message'), 'fresh');
  });

  testWidgets(
    'permission loss erases accepted results and stops remaining chunks',
    (tester) async {
      final pending = Completer<List<PriceCheckResult>>();
      var count = 0;
      final batch = PriceCheckBatchController((items, cancelToken) {
        count++;
        expect(items.length, lessThanOrEqualTo(100));
        return pending.future;
      });
      addTearDown(batch.dispose);
      batch.update([for (var i = 0; i < 201; i++) item('$i')], enabled: true);
      await tester.pump(const Duration(milliseconds: 300));
      batch.update([], enabled: false);
      pending.complete([result('0')]);
      await tester.pump();
      expect(count, 1);
      expect(batch.result('0'), isNull);
    },
  );

  testWidgets(
    'failure is unavailable, and an unrelated goods response is rejected',
    (tester) async {
      var fail = true;
      final batch = PriceCheckBatchController((items, cancelToken) async {
        if (fail) throw StateError('offline');
        return [
          const PriceCheckResult({
            'rowKey': 'a',
            'goodsId': 'other',
            'status': 'READY',
            'severity': 'WARNING',
          }),
        ];
      });
      addTearDown(batch.dispose);
      batch.update([item('a')], enabled: true);
      await tester.pump(const Duration(milliseconds: 300));
      expect(batch.result('a')!.text('status'), 'UNAVAILABLE');
      fail = false;
      batch.update([item('a', price: '14')], enabled: true);
      await tester.pump(const Duration(milliseconds: 300));
      expect(batch.result('a')!.warning, isFalse);
    },
  );

  test(
    'assessment captures authoritative total and frozen rate without mutating the row',
    () {
      final row = PurchaseGridRow(supportsTotalInput: true)
        ..goods = const GoodsOption(id: 'goods', name: 'material')
        ..unitId = 'unit'
        ..unitRateText = '1.000001'
        ..currencyId = 'cny'
        ..supplierId = 'supplier';
      addTearDown(row.dispose);
      row.qty.text = '3000';
      row.pricing.totalAmount.text = '100';
      row.taxRate.text = '13';
      final priceBefore = row.price.text;
      final payload = purchasePriceCheckBinding(row).payload()!;
      expect(payload['totalAmountInput'], '100');
      expect(payload['quantity'], '3000');
      expect(payload['unitRate'], '1.000001');
      expect(row.price.text, priceBefore);
      expect(row.pricing.totalAmountInput, '100');
    },
  );

  test(
    'purchase gifts remain explicit and malformed inputs do not poison a batch',
    () {
      final row = PurchaseGridRow(supportsTotalInput: true)
        ..goods = const GoodsOption(id: 'goods', name: 'material');
      addTearDown(row.dispose);
      row.qty.text = '10';
      row.price.text = '12';
      row.giftQty.text = '2';
      expect(purchasePriceCheckBinding(row).payload()!['giftQuantity'], '2');
      row.qty.text = '-';
      expect(purchasePriceCheckBinding(row).payload(), isNull);
      row.qty.text = '0';
      expect(purchasePriceCheckBinding(row).payload(), isNull);
    },
  );

  test('subcontract frozen decimal rate survives drafts and clone', () {
    final row = SubcontractGridRow(supportsTotalInput: true)
      ..goods = const GoodsOption(id: 'goods', name: 'part')
      ..unitRate = 1
      ..unitRateText = '1.000001';
    addTearDown(row.dispose);
    row.qty.text = '3';
    row.price.text = '2';
    final copy = row.clone();
    addTearDown(copy.dispose);
    expect(
      subcontractPriceCheckBinding(copy).payload()!['unitRate'],
      '1.000001',
    );
    expect(subcontractPriceCheckBinding(copy).payload()!['giftQuantity'], '0');
    copy.unitRate = 2;
    expect(subcontractPriceCheckBinding(copy).payload()!['unitRate'], '2.0');
  });

  test(
    'deep route requires analysis and goods permissions without category access',
    () {
      const path = '/basicinfo/goods/id/price-analysis';
      expect(requiredAnyPermFor(path), [Perm.goodsPriceAnalysisView]);
      expect(
        locationAllowedFor(
          {Perm.goodsView, Perm.materialCategoryView},
          false,
          path,
        ),
        isFalse,
      );
      expect(
        locationAllowedFor(
          {Perm.goodsPriceAnalysisView, Perm.materialCategoryView},
          false,
          path,
        ),
        isFalse,
      );
      expect(
        locationAllowedFor(
          {Perm.goodsView, Perm.goodsPriceAnalysisView},
          false,
          '$path?kind=SALES',
        ),
        isTrue,
      );
    },
  );
}
