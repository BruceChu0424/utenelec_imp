// 库存重量读模型契约 (ADR-135): 千克, null = 未知 (绝不当 0), 估算单独标记。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';
import 'package:uten_imp/shared/stock_ledger/stock_ledger_models.dart';

void main() {
  test('balance row parses weight kg and the estimated flag', () {
    final row = BalanceRow.fromJson({
      'id': 'balance-1',
      'qty': 12.5,
      'weight': 7.25,
      'weightEstimated': true,
    });
    expect(row.qty, 12.5);
    expect(row.weight, 7.25);
    expect(row.weightEstimated, isTrue);

    final unknown = BalanceRow.fromJson({'id': 'balance-2', 'qty': 3});
    expect(unknown.weight, isNull, reason: '没称过的余额重量是未知, 不是 0');
    expect(unknown.weightEstimated, isFalse);
  });

  test('balance adjustment result carries the weight fixed with it', () {
    Map<String, dynamic> result(Object? afterWeightKg) => {
      'documentId': 'doc-1',
      'billNo': 'PD-001',
      'beforeQty': 10,
      'afterQty': 12,
      'deltaQty': 2,
      'adjustedByName': '张三',
      'adjustedAt': '2026-09-28T02:00:00Z',
      'afterWeightKg': afterWeightKg,
    };
    expect(
      StockBalanceAdjustmentResult.fromJson(result(3.25)).afterWeightKg,
      3.25,
    );
    expect(
      StockBalanceAdjustmentResult.fromJson(result(null)).afterWeightKg,
      isNull,
      reason: '本次没有改重量',
    );
  });

  test('instant inventory row parses weight flags and learned unit weight', () {
    final row = InstantInventoryRow.fromJson({
      'goodsId': 'g1',
      'qty': 100,
      'weight': null,
      'weightEstimated': false,
      'weightUnknown': true,
      'unitWeightKg': 0.002312,
      'weightTier': 'YELLOW',
    });
    expect(row.weight, isNull);
    expect(row.weightUnknown, isTrue);
    expect(row.unitWeightKg, closeTo(0.002312, 1e-12));
    expect(row.weightTier, 'YELLOW');

    final known = InstantInventoryRow.fromJson({
      'goodsId': 'g2',
      'weight': 3.52,
      'weightEstimated': true,
      'weightUnknown': false,
    });
    expect(known.weightUnknown, isFalse);
    expect(known.weightEstimated, isTrue);
  });

  test('stock item detail page is a thin host of the shared ledger panel', () {
    // 余额/流水/单重学习三段与货品详情「库存与出入库」页签同一个面板 (lib/shared)。
    final source = File(
      'lib/features/stock/pages/stock_item_detail_page.dart',
    ).readAsStringSync();
    expect(source, contains('GoodsStockLedgerPanel('));
    expect(
      source,
      contains('GoodsStockLedgerSegment.parse(widget.initialTab)'),
    );
    expect(source, isNot(contains('MovementRow')));
    expect(source, isNot(contains('movementTypeLabel')));

    expect(
      GoodsStockLedgerSegment.parse('ledger'),
      GoodsStockLedgerSegment.ledger,
    );
    expect(
      GoodsStockLedgerSegment.parse('WEIGHT'),
      GoodsStockLedgerSegment.weight,
    );
    expect(
      GoodsStockLedgerSegment.parse(null),
      GoodsStockLedgerSegment.balance,
    );
    expect(GoodsStockLedgerSegment.parse('x'), GoodsStockLedgerSegment.balance);
  });

  test('old movement list model and endpoint are gone', () {
    final model = File(
      'lib/features/stock/models/stock_query.dart',
    ).readAsStringSync();
    final repo = File(
      'lib/features/stock/repositories/stock_query_repository.dart',
    ).readAsStringSync();
    final endpoints = File(
      'lib/core/network/api_endpoints.dart',
    ).readAsStringSync();
    expect(model, isNot(contains('class MovementRow')));
    expect(model, isNot(contains('movementTypeLabel')));
    expect(repo, isNot(contains('movements(')));
    expect(endpoints, isNot(contains("'/stock/movements'")));
    expect(repo, contains("'targetWeightKg': ?targetWeightKg"));
  });
}
