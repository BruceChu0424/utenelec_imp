import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_table_row_drag.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  for (final drag in ['行', '表头横向', '表头纵向']) {
    for (final change in ['卸载', '重挂载', '路由覆盖']) {
      testWidgets('$drag拖拽中$change安全取消，不提交拖拽且页面仍可点击', (tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final navigator = GlobalKey<NavigatorState>();
        final tableKey = GlobalKey();
        var visible = true;
        var moved = false;
        var selected = <String>{};
        var drops = 0;
        var actions = 0;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: Scaffold(
              body: StatefulBuilder(
                builder: (_, setState) {
                  update = setState;
                  final table = MasterDataTableView<String>(
                    key: tableKey,
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
                    items: const ['拖拽A', '拖拽B'],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    selectable: true,
                    idOf: (row) => row,
                    selectedIds: selected,
                    onSelectedIdsChanged: (ids) =>
                        setState(() => selected = ids),
                    rowDrag: UtenTableRowDrag<String>(
                      canDragRow: (_) => true,
                      dragRowsOf: (row) => [row],
                      dragLabelOf: (row) => row,
                      canDrop: (target, rows) => !rows.contains(target),
                      onDrop: (_, _, _) async => drops++,
                    ),
                  );
                  return Column(
                    children: [
                      TextButton(
                        onPressed: () => actions++,
                        child: const Text('页面操作'),
                      ),
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: visible && !moved
                                  ? table
                                  : const SizedBox.shrink(),
                            ),
                            Expanded(
                              child: visible && moved
                                  ? table
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(find.text(drag == '行' ? '拖拽A' : '名称')),
          kind: PointerDeviceKind.mouse,
        );
        if (drag == '行') {
          await tester.pump(const Duration(milliseconds: 600));
          await gesture.moveTo(tester.getCenter(find.text('拖拽B')));
        } else {
          await gesture.moveBy(
            drag == '表头横向' ? const Offset(80, 0) : const Offset(0, 80),
          );
        }
        await tester.pumpAndSettle();
        expect(
          find.text(drag == '行' ? '拖拽A' : '名称'),
          findsNWidgets(2),
          reason: '先确认真实拖拽幽灵层已经出现',
        );
        if (change == '路由覆盖') {
          navigator.currentState!.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: TextButton(
                  onPressed: () => actions++,
                  child: const Text('新页操作'),
                ),
              ),
            ),
          );
        } else {
          update(() {
            if (change == '卸载') {
              visible = false;
            } else {
              moved = true;
            }
          });
        }
        await tester.pumpAndSettle();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(drops, 0);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text(change == '路由覆盖' ? '新页操作' : '页面操作'));
        await tester.pumpAndSettle();
        expect(actions, 1);
        if (change == '路由覆盖') {
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
        }
        if (visible) {
          expect(find.text('拖拽A'), findsOneWidget);
          expect(find.text('名称'), findsOneWidget);
          expect(find.text('状态'), findsOneWidget);
          expect(
            tester.getCenter(find.text('名称')).dx,
            lessThan(tester.getCenter(find.text('状态')).dx),
          );
        } else {
          expect(find.text('拖拽A'), findsNothing);
          expect(find.text('名称'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
