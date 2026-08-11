// Feature 2：表体 SelectionArea 文字选择决策门测试。
//
// D-11 表体存在 SelectionArea；D-13 鼠标点行仍触发 onRowTap（FM1 安全网——
//    验证 SelectionArea 的 mouse TapAndPanGestureRecognizer 不抢 InkWell 的点按，
//    期望通过：命中分发"最深优先"+ InkWell 更早 resolve(accepted) → 行导航正常）；
// D-12 触屏点行仍导航；D-15 大表拖选+滚+刷新不崩（FM2 把关，best-effort）。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(this.id);
  final String id;
}

Widget _table({
  required List<_Row> items,
  void Function(_Row)? onRowTap,
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
        ),
      ),
    ),
  );
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
    'mouse tap on row still fires onRowTap inside SelectionArea (FM1 safety net)',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _table(items: const [_Row('a1'), _Row('a2')], onRowTap: (_) => taps++),
      );
      await tester.pumpAndSettle();

      // 鼠标点按第 1 行（SelectionArea 已包表体）。
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('a1')),
        pointer: 0,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pump();

      // 期望：InkWell 赢竞技场，导航不被 SelectionArea 抢。
      expect(taps, 1);
    },
  );

  testWidgets('touch tap on row still navigates with SelectionArea present', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _table(items: const [_Row('a1')], onRowTap: (_) => taps++),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('a1'));
    await tester.pump();

    expect(taps, 1);
  });

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
}
