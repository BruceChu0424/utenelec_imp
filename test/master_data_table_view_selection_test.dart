// Feature 2：表体 SelectionArea 文字选择决策门测试。
//
// D-11 表体存在 SelectionArea；D-13 鼠标双击行仍触发 onRowTap（FM1 安全网——
//    验证 SelectionArea 的 mouse TapAndPanGestureRecognizer 不抢 InkWell 的点按，
//    期望通过：命中分发"最深优先"+ InkWell 更早 resolve(accepted) → 行导航正常）。
//    新交互契约：单击只选中（不触发 onRowTap），双击才打开（手动时间窗判定，
//    无 DoubleTapGestureRecognizer 竞技场 hold，不影响文本拖选）。
// D-12 触屏双击行仍导航；D-15 大表拖选+滚+刷新不崩（FM2 把关，best-effort）。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(this.id);
  final String id;
}

Widget _table({
  required List<_Row> items,
  void Function(_Row)? onRowTap,
  void Function(_Row)? onSelectionChanged,
  double height = 200,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 640,
        height: height,
        child: MasterDataTableView<_Row>(
          columns: [
            MasterColumnDef<_Row>(
              key: 'id',
              label: 'ID',
              width: 240,
              value: (r) => r.id,
            ),
          ],
          items: items,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          onRowTap: onRowTap,
          onSelectionChanged: onSelectionChanged,
        ),
      ),
    ),
  );
}

/// 双击指定行（两次点按间隔 50ms，落在 350ms 手动双击判定窗内）。
Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  testWidgets('body is wrapped in SelectionArea (cells selectable)', (
    tester,
  ) async {
    await tester.pumpWidget(_table(items: const [_Row('a1')]));
    await tester.pumpAndSettle();

    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets(
    'single click selects without opening (new contract: click = select)',
    (tester) async {
      var opens = 0;
      var selects = 0;
      await tester.pumpWidget(
        _table(
          items: const [_Row('a1'), _Row('a2')],
          onRowTap: (_) => opens++,
          onSelectionChanged: (_) => selects++,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('a1'));
      await tester.pump();

      // 单击：立即选中、绝不打开；pump 过双击窗口后依然不打开。
      expect(selects, 1);
      expect(opens, 0);
      await tester.pump(const Duration(milliseconds: 400));
      expect(opens, 0);
    },
  );

  testWidgets(
    'mouse double click on row fires onRowTap inside SelectionArea (FM1 safety net)',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _table(items: const [_Row('a1'), _Row('a2')], onRowTap: (_) => taps++),
      );
      await tester.pumpAndSettle();

      // 鼠标双击第 1 行（SelectionArea 已包表体）。
      final center = tester.getCenter(find.text('a1'));
      var gesture = await tester.startGesture(
        center,
        pointer: 0,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
      gesture = await tester.startGesture(
        center,
        pointer: 1,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pump();

      // 期望：InkWell 赢竞技场，双击打开不被 SelectionArea 抢。
      expect(taps, 1);
    },
  );

  testWidgets('touch double tap on row navigates with SelectionArea present', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _table(items: const [_Row('a1')], onRowTap: (_) => taps++),
    );
    await tester.pumpAndSettle();

    await _doubleTapRow(tester, find.text('a1'));

    expect(taps, 1);
  });

  testWidgets(
    'selectable row remains selected when an already selected row is double clicked',
    (tester) async {
      var opens = 0;
      var selected = <String>{'a1'};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 640,
              height: 200,
              child: StatefulBuilder(
                builder: (context, setState) {
                  return MasterDataTableView<_Row>(
                    columns: [
                      MasterColumnDef<_Row>(
                        key: 'id',
                        label: 'ID',
                        width: 240,
                        value: (row) => row.id,
                      ),
                    ],
                    items: const [_Row('a1'), _Row('a2')],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    selectable: true,
                    idOf: (row) => row.id,
                    selectedIds: selected,
                    onSelectedIdsChanged: (next) {
                      setState(() => selected = next);
                    },
                    onRowTap: (_) => opens++,
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _doubleTapRow(tester, find.text('a1'));

      expect(opens, 1);
      expect(selected, {'a1'});
    },
  );

  testWidgets(
    'large table: select + scroll + refresh does not throw (FM2 CME gate)',
    (tester) async {
      await tester.pumpWidget(
        _table(
          items: [for (var i = 0; i < 300; i++) _Row('ROW-$i')],
          height: 300,
        ),
      );
      await tester.pumpAndSettle();

      // 鼠标拖选第 0 行，向下拖过视口（触发 auto-scroll + 行虚拟化 dispose）。
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('ROW-0')),
        pointer: 0,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(const Offset(0, 400));
      await tester.pump();
      // 模拟刷新：换一批新的 item 对象（强制 cell 重建/dispose），观察是否抛
      // ConcurrentModificationError（_flushInactiveSelections 惰性迭代中途 dispose）。
      await tester.pumpWidget(
        _table(
          items: [for (var i = 0; i < 300; i++) _Row('ROW-$i')],
          height: 300,
        ),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // 无异常即通过（test framework 会把 CME 当异常上报→测试失败）。
      expect(find.byType(SelectionArea), findsOneWidget);
    },
  );

  testWidgets(
    'batch actions float at bottom-right and remain available in fullscreen',
    (tester) async {
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var selected = <String>{};
      var runs = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => MasterDataTableView<_Row>(
                columns: [
                  MasterColumnDef<_Row>(
                    key: 'id',
                    label: 'ID',
                    width: 240,
                    value: (row) => row.id,
                  ),
                ],
                items: const [_Row('a1'), _Row('a2')],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                selectable: true,
                idOf: (row) => row.id,
                selectedIds: selected,
                onSelectedIdsChanged: (next) => setState(() => selected = next),
                batchActionsBuilder: (_, ids) => [
                  UtenButton(
                    key: const Key('floating-batch-action'),
                    size: UtenButtonSize.large,
                    onPressed: () => runs++,
                    child: Text('处理(${ids.length})'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('已选 0 项'), findsOneWidget);
      final action = find.byKey(const Key('floating-batch-action'));
      expect(action, findsOneWidget);
      final actionCenter = tester.getCenter(action);
      expect(actionCenter.dx, greaterThan(650));
      expect(actionCenter.dy, greaterThan(430));

      await tester.tap(find.text('a1'));
      await tester.pump();
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(action);
      expect(runs, 1);

      await tester.tap(find.text('全屏'));
      await tester.pumpAndSettle();
      expect(action, findsOneWidget);
      await tester.tap(action);
      expect(runs, 2);
    },
  );
}
