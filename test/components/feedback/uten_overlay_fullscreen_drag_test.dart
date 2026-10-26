import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_table_row_drag.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

Future<void> _table(
  WidgetTester tester, {
  void Function(String source, String target)? onDrop,
}) async {
  var selected = <String>{};
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (_, setState) => MasterDataTableView<String>(
            columns: [
              MasterColumnDef<String>(
                key: 'name',
                label: '名称',
                width: 220,
                value: (row) => row,
              ),
              MasterColumnDef<String>(
                key: 'status',
                label: '状态',
                width: 120,
                value: (_) => '使用',
              ),
            ],
            items: const ['全屏A', '全屏B'],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            selectable: true,
            idOf: (row) => row,
            selectedIds: selected,
            onSelectedIdsChanged: (ids) => setState(() => selected = ids),
            rowDrag: UtenTableRowDrag<String>(
              canDragRow: (_) => true,
              dragRowsOf: (row) => [row],
              dragLabelOf: (row) => row,
              canDrop: (target, rows) => !rows.contains(target),
              onDrop: (rows, target, _) async =>
                  onDrop?.call(rows.single, target),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('全屏'));
  await tester.pumpAndSettle();
  expect(find.text('退出全屏'), findsOneWidget);
}

void main() {
  testWidgets('全屏表格使用实际展示route的所有权，拖行仍能合法提交', (tester) async {
    final drops = <(String, String)>[];
    await _table(
      tester,
      onDrop: (source, target) => drops.add((source, target)),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('全屏A')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 600));
    final target = tester.getRect(
      find.byKey(const ValueKey('row-drag-slot:全屏B')),
    );
    await gesture.moveTo(Offset(target.center.dx, target.bottom - 3));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(drops, [('全屏A', '全屏B')]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全屏表格表头横拖仍能换列，不受被盖住的原页面route影响', (tester) async {
    await _table(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('名称')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(230, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.text('状态')).dx,
      lessThan(tester.getCenter(find.text('名称')).dx),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('全屏表格表头纵拖仍能隐藏非末列', (tester) async {
    await _table(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('名称')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 90));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('名称'), findsNothing);
    expect(find.text('状态'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
