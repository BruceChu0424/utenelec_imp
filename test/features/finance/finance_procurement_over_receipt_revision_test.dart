// ADR-144 采购允许超收% 在财务订货审核里的对比口径：
//  - 键 allowedOverReceiptPct 从审核行 JSON 读出(十进制原文)；
//  - 比例在审批哈希快照里(非空才出现)，展示快照不完整的历史行也如实比较；
//  - 空与 0 同义(都不允许超收)，小数尾零不算修改。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_revision.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_workflow.dart';

FinanceProcurementReviewLine _line({
  String? pct,
  bool displaySnapshotComplete = true,
}) => FinanceProcurementReviewLine.fromJson({
  'lineNo': 1,
  'orderItemId': 'item-1',
  'goodsId': 'goods-1',
  'qty': '100',
  'price': '2',
  'displaySnapshotComplete': displaySnapshotComplete,
  'allowedOverReceiptPct': ?pct,
});

void main() {
  test('审核行读出允许超收原文', () {
    expect(_line(pct: '5.00').allowedOverReceiptPct, '5.00');
    expect(_line().allowedOverReceiptPct, isNull);
  });

  test('比例改动标记 allowedOverReceiptPct，展示快照不完整也能比', () {
    final before = _line(pct: '5', displaySnapshotComplete: false);
    final after = _line(pct: '8.5', displaySnapshotComplete: false);
    expect(procurementChangedFields(before, after), {'allowedOverReceiptPct'});
    final rows = procurementRevisionRows([before], [after]);
    expect(rows.single.unchanged, isFalse);
    expect(rows.single.needsReview, isFalse);
  });

  test('空与 0、尾零差异都不算修改', () {
    expect(procurementChangedFields(_line(), _line(pct: '0')), isEmpty);
    expect(
      procurementChangedFields(_line(pct: '5.00'), _line(pct: '5')),
      isEmpty,
    );
    expect(
      procurementRevisionRows(
        [_line(pct: '5.00')],
        [_line(pct: '5')],
      ).single.unchanged,
      isTrue,
    );
  });

  test('从不允许改成允许超收是修改', () {
    expect(procurementChangedFields(_line(), _line(pct: '3')), {
      'allowedOverReceiptPct',
    });
  });
}
