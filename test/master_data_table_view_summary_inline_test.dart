// 合计条随表体滚动（summaryBarInline）口径回归：
// 2026-09-15 用户口径——合计条属于表格那一块，渲染进表体滚动内容末尾（最后一行
// 数据之下），不钉在区块底部/按钮上方：行多时要滚到底才见；行少时紧贴末行。
// 对照口径（inline:false）：钉在表体之外、不滚动也始终可见。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

const _summaryText = 'TOTAL-BAR-MARKER';

List<String> get _rows => List.generate(60, (i) => 'ROW-$i');

Widget _table({required bool inline}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 640,
        child: MasterDataTableView<String>(
          columns: const [
            MasterColumnDef<String>(
              key: 'value',
              label: '值',
              width: 240,
              value: _identity,
            ),
          ],
          items: _rows,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          summaryBar: const Text(_summaryText),
          summaryBarInline: inline,
        ),
      ),
    ),
  );
}

String _identity(String value) => value;

Future<void> _dragUp(WidgetTester tester) async {
  // 行高随字号/密度变化，不假设具体哪行可见：取当前真正可命中的数据行拖动
  //（hitTestable 排除 ListView cacheExtent 里已构建但不可点的行）。
  final visibleRow = find.textContaining('ROW-').hitTestable().first;
  expect(visibleRow, findsOneWidget);
  await tester.drag(visibleRow, const Offset(0, -400));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('inline 合计条：首屏不可见，滚到表底才出现在末行之下', (tester) async {
    await tester.pumpWidget(_table(inline: true));
    await tester.pumpAndSettle();

    // 行多（60 行远超 600 高视口）：合计条在滚动内容末尾，首屏不构建也不可见。
    expect(find.text('ROW-0'), findsOneWidget);
    expect(find.text(_summaryText), findsNothing);

    // 连续上滚把表体滚到底：合计条作为内容末项进入可视区（跟着表格最下面）。
    for (var i = 0; i < 12 && find.text(_summaryText).evaluate().isEmpty; i++) {
      await _dragUp(tester);
    }
    expect(find.text(_summaryText), findsOneWidget);
    // 滚到底后末行与合计条同屏：合计条在最后一行数据之下。
    expect(find.text('ROW-59'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(_summaryText)).dy,
      greaterThan(tester.getTopLeft(find.text('ROW-59')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('钉底合计条（inline:false）对照：不滚动也始终可见', (tester) async {
    await tester.pumpWidget(_table(inline: false));
    await tester.pumpAndSettle();

    // 钉在表体之外：首屏（未滚动）即可见。
    expect(find.text(_summaryText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
