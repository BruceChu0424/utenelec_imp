import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_revision.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_workflow.dart';

FinanceProcurementReviewLine line(
  String id,
  String goods,
  String qty, {
  String? amount,
}) => FinanceProcurementReviewLine(
  orderItemId: id,
  lineNo: 1,
  goodsId: goods,
  goodsName: goods,
  unitId: 'unit-1',
  qty: qty,
  price: '2',
  amountOriginal: amount,
  displaySnapshotComplete: true,
);

void main() {
  test(
    'changed cell keys normalize decimals and retain the changed currency',
    () {
      const before = FinanceProcurementReviewLine(
        displaySnapshotComplete: true,
        lineNo: 2,
        qty: '10.000',
        price: '2.00',
        unitRate: '1.000',
        amountOriginal: '20.00',
        currencyName: '美元',
      );
      const equivalent = FinanceProcurementReviewLine(
        displaySnapshotComplete: true,
        lineNo: 1,
        qty: '10',
        price: '2',
        unitRate: '1',
        amountOriginal: '20',
        currencyName: '美元',
      );
      const changed = FinanceProcurementReviewLine(
        displaySnapshotComplete: true,
        lineNo: 1,
        qty: '12',
        price: '2',
        unitRate: '1',
        amountOriginal: '24',
        currencyName: '人民币',
      );
      expect(procurementChangedFields(before, equivalent), isEmpty);
      expect(procurementChangedFields(before, changed), {
        'qty',
        'amountOriginal',
        'currencyName',
      });
    },
  );

  test('keeps unchanged rows neutral when draft save recreates row IDs', () {
    final rows = procurementRevisionRows(
      [line('old-a', 'a', '10.000'), line('old-b', 'b', '20')],
      [line('new-a', 'a', '10'), line('new-b', 'b', '25')],
    );
    expect(rows.first.unchanged, isTrue);
    expect(rows.last.unchanged, isFalse);
    expect(rows.last.before!.qty, '20');
    expect(rows.last.after!.qty, '25');
  });

  test(
    'only loss allowance, weight, remark or source allocation edits are visible',
    () {
      final old = FinanceProcurementReviewLine.fromJson({
        'lineNo': 1,
        'orderItemId': 'item',
        'goodsId': 'goods',
        'qty': '10',
        'displaySnapshotComplete': true,
        'weight': '1.25',
        'allowedLossPct': '2.50',
        'remark': '旧备注',
        'sourceAllocations':
            '[{"sourceItemId":"a","quantity":"5"},{"sourceItemId":"b","quantity":"5"}]',
      });
      final next = FinanceProcurementReviewLine.fromJson({
        'lineNo': 1,
        'orderItemId': 'item',
        'goodsId': 'goods',
        'qty': '10',
        'displaySnapshotComplete': true,
        'weight': '2.75',
        'allowedLossPct': '3.75',
        'remark': null,
        'sourceAllocations':
            '[{"sourceItemId":"a","quantity":"4"},{"sourceItemId":"b","quantity":"6"}]',
      });
      expect(procurementChangedFields(old, next), {
        'weight',
        'allowedLossPct',
        'remark',
        'sourceApplicationNos',
      });
      expect(procurementRevisionRows([old], [next]).single.unchanged, isFalse);
    },
  );

  test(
    'legacy missing facts require checking but never claim a known change',
    () {
      final old = FinanceProcurementReviewLine.fromJson({
        'lineNo': 1,
        'orderItemId': 'item',
        'goodsId': 'goods',
        'qty': '10',
        'goodsName': '现在的主档名称',
      });
      final next = FinanceProcurementReviewLine.fromJson({
        'lineNo': 1,
        'orderItemId': 'item',
        'goodsId': 'goods',
        'qty': '10.000',
        'goodsName': '提交时名称',
        'displaySnapshotComplete': true,
        'remark': '本次备注',
      });
      expect(procurementChangedFields(old, next), isEmpty);
      final comparison = procurementRevisionRows([old], [next]).single;
      expect(comparison.needsReview, isTrue);
      expect(comparison.unchanged, isFalse);
      expect(
        procurementHeaderChanges(
          {'billDate': '2026-09-23'},
          {'billDate': '2026-09-23', 'remark': null},
        ),
        isEmpty,
      );
      expect(
        procurementHeaderUnknownLabels(
          {'billDate': '2026-09-23'},
          {'billDate': '2026-09-23', 'remark': null},
        ),
        ['备注'],
      );
    },
  );

  test(
    'known header changes include remark clearing and every editable term',
    () {
      final before = <String, dynamic>{
        'billDate': '2026-09-22',
        'supplierId': 's1',
        'supplierName': '旧供应商',
        'warehouseId': 'w1',
        'warehouseName': '旧仓',
        'currencyId': 'c1',
        'currencyName': '美元',
        'exchangeRate': '7.1',
        'taxRate': '13',
        'settlementMethodId': 't1',
        'settlementMethodName': '现结',
        'purchaserEmployeeId': 'p1',
        'purchaserName': '甲',
        'deliverDate': '2026-10-01',
        'remark': '原备注',
      };
      final after = {
        ...before,
        'billDate': '2026-09-23',
        'supplierId': 's2',
        'supplierName': '新供应商',
        'warehouseId': 'w2',
        'warehouseName': '新仓',
        'currencyId': 'c2',
        'currencyName': '人民币',
        'exchangeRate': '1',
        'taxRate': '0',
        'settlementMethodId': 't2',
        'settlementMethodName': '月结',
        'purchaserEmployeeId': 'p2',
        'purchaserName': '乙',
        'deliverDate': '2026-10-02',
        'remark': null,
      };
      final changes = procurementHeaderChanges(before, after);
      expect(changes.map((change) => change.key).toSet(), {
        'billDate',
        'supplierId',
        'warehouseId',
        'currencyId',
        'exchangeRate',
        'taxRate',
        'settlementMethodId',
        'purchaserEmployeeId',
        'deliverDate',
        'remark',
      });
      expect(
        changes.singleWhere((change) => change.key == 'remark').after,
        '未填写',
      );
      expect(
        procurementHeaderChanges(
          {'exchangeRate': '1.000'},
          {'exchangeRate': '1'},
        ),
        isEmpty,
      );
    },
  );

  test('retains a deleted old row and appends the complete new row', () {
    final rows = procurementRevisionRows(
      [line('old', 'a', '10', amount: '19.999999999999')],
      [line('added', 'b', '30', amount: '60')],
    );
    expect(rows, hasLength(2));
    expect(rows.first.after, isNull);
    expect(rows.first.before!.amountOriginal, '19.999999999999');
    expect(rows.last.before, isNull);
    expect(rows.last.after!.goodsName, 'b');
  });

  test(
    'reserves exact duplicate-goods matches before pairing changed rows',
    () {
      final rows = procurementRevisionRows(
        [line('old-a', 'same', '10'), line('old-b', 'same', '20')],
        [line('new-a', 'same', '20'), line('new-b', 'same', '15')],
      );
      expect(rows.first.before!.qty, '10');
      expect(rows.first.after!.qty, '15');
      expect(rows.last.unchanged, isTrue);
    },
  );

  test('does not guess pairings for ambiguous duplicate goods', () {
    final rows = procurementRevisionRows(
      [line('old-a', 'same', '10'), line('old-b', 'same', '20')],
      [line('new-a', 'same', '12'), line('new-b', 'same', '24')],
    );
    expect(rows.where((row) => row.after == null), hasLength(2));
    expect(rows.where((row) => row.before == null), hasLength(2));
  });
}
