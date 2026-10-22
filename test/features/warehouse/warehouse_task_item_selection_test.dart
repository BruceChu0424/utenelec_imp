import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_item_selection.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_center_record.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_record_actions.dart';

void main() {
  test('an explicit scope never becomes whole-document selection', () {
    final selected = WarehouseTaskItemSelection(['line-a']);
    selected.validate(['line-a', 'line-b']);
    expect(selected.contains('line-a'), isTrue);
    expect(selected.contains('line-b'), isFalse);
    expect(() => selected.validate(['line-b']), throwsFormatException);
    expect(
      () => WarehouseTaskItemSelection([]).validate(['line-a']),
      throwsFormatException,
    );
    expect(
      () =>
          WarehouseTaskItemSelection(['line-a', 'line-a']).validate(['line-a']),
      throwsFormatException,
    );
  });

  test(
    'all physical identities survive target normalization on the same document',
    () {
      WarehouseTaskCenterRecord row(String item) => WarehouseTaskCenterRecord(
        rowKey: 'DRAW:doc:$item',
        id: 'doc',
        targetId: 'doc',
        sourceType: 'DRAW',
        recordType: 'STOCK_DOCUMENT',
        status: 'READY',
        statusLabel: '待出库',
        action: 'PRODUCTION_DRAW',
        canHandle: true,
        line: WarehouseTaskLine(key: item, itemId: item),
      );
      expect(
        warehouseTaskCommandTargets([
          row('a'),
          row('b'),
          row('a'),
        ]).map((row) => row.line!.itemId),
        ['a', 'b'],
      );
    },
  );
  test('suggestion ordinals retain separate identities without item UUIDs', () {
    WarehouseTaskCenterRecord row(int ordinal) => WarehouseTaskCenterRecord(
      rowKey: 'DRAW:MATERIAL_DISCOVERY:request:suggestion-$ordinal',
      id: 'request',
      targetId: 'request',
      sourceType: 'DRAW',
      recordType: 'MATERIAL_DISCOVERY',
      status: 'PENDING',
      statusLabel: '待核对',
      action: 'MATERIAL_DISCOVERY',
      canHandle: true,
      actionData: const {'materialsDefined': true, 'expectedVersion': 7},
      line: WarehouseTaskLine(key: 'suggestion-$ordinal'),
    );
    expect(
      warehouseTaskCommandTargets([
        row(1),
        row(2),
        row(1),
      ]).map((row) => row.line!.key),
      ['suggestion-1', 'suggestion-2'],
    );
  });
}
