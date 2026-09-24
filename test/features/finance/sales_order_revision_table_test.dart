import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_revision_table.dart';
import 'package:uten_imp/features/finance/models/sales_order_finance_confirmation.dart';
import 'package:uten_imp/features/finance/widgets/sales_order_revision_table.dart';

SalesOrderRevisionLine line(String id, String qty) => SalesOrderRevisionLine(
  itemId: id,
  goodsName: '同名货品',
  goodsCode: 'G-01',
  values: {'数量': qty},
);

void main() {
  test('只改数量、删除、新增与同货品不同明细分别保留真实身份', () {
    final diff = SalesOrderRevisionDiff(
      beforeItems: [
        line('changed', '10'),
        line('same', '2'),
        line('deleted', '3'),
      ],
      afterItems: [line('changed', '6'), line('same', '2'), line('new', '4')],
      changedItemIds: const {'changed', 'deleted', 'new'},
      headerChanges: const [],
    );
    final rows = salesOrderRevisionRows(diff);
    expect(rows.map((row) => row.value.itemId), [
      'changed',
      'changed',
      'same',
      'deleted',
      'new',
    ]);
    expect(rows.map((row) => row.kind), [
      UtenRevisionKind.removed,
      UtenRevisionKind.added,
      UtenRevisionKind.unchanged,
      UtenRevisionKind.removed,
      UtenRevisionKind.added,
    ]);
    expect(rows.map((row) => row.value.values['数量']), [
      '10',
      '6',
      '2',
      '3',
      '4',
    ]);
    expect(rows[1].changedKeys, {'数量'});
    expect(rows.last.changedKeys, isEmpty);
  });

  test('历史只存改量的记录不把其他当前行误报为新增', () {
    final rows = salesOrderRevisionRows(
      SalesOrderRevisionDiff(
        beforeItems: [line('changed', '10')],
        afterItems: [line('changed', '6'), line('same', '2')],
        changedItemIds: const {'changed'},
        headerChanges: const [],
        baselineComplete: false,
      ),
    );
    expect(rows.last.kind, UtenRevisionKind.unchanged);
  });

  test('修改后又改回原值只显示未变行', () {
    final original = line('same', '2');
    final rows = salesOrderRevisionRows(
      SalesOrderRevisionDiff(
        beforeItems: [original],
        afterItems: [original],
        changedItemIds: const {},
        headerChanges: const [],
      ),
    );
    expect(rows.single.kind, UtenRevisionKind.unchanged);
  });
}
