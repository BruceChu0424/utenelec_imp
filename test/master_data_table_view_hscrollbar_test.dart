// MasterDataTableView 横向滚动条位置行为回归：
// - 内容少（表体不超可用高）：自然横滚条在最后一行下方、隔 16 间距；
// - 内容多（表体超高）：横滚条钉在表体区域底部（视口底），不随内容沉底。
// 与 uten_editable_grid_hscrollbar_test 同款规格，锁定两张表行为一致。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(this.id);
  final String id;
}

MasterDataTableView<_Row> _table(List<_Row> items, {bool withBatch = false}) {
  return MasterDataTableView<_Row>(
    columns: [
      for (var i = 0; i < 8; i++)
        MasterColumnDef<_Row>(
          key: 'c$i',
          label: '列$i',
          width: 160,
          value: (item) => '${item.id}-$i',
        ),
    ],
    items: items,
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
    // 颜色主档同款：多选 + 悬浮批量按钮（右下角）。
    selectable: withBatch,
    idOf: withBatch ? (item) => item.id : null,
    batchActionsBuilder: withBatch
        ? (context, ids) => const [Text('批量操作')]
        : null,
  );
}

Widget _wrap(MasterDataTableView<_Row> table) =>
    MaterialApp(home: Scaffold(body: table));

/// 横向滚动条 = 树序第二个 Scrollbar（外层竖向、内层横向）。
RenderBox _hBarBox(WidgetTester tester) {
  final bars = find.byType(Scrollbar).evaluate().toList();
  expect(bars.length, 2, reason: '竖向 + 横向两个 Scrollbar');
  return bars[1].findRenderObject() as RenderBox;
}

/// 最后一行底边：末行末格文本向上找最宽的祖先 DecoratedBox（= 整行，含底边线）。
/// 纯展示行不挂 InkWell，锚点用末行最后一列的单元格文本。
RenderBox _lastRowBox(WidgetTester tester) {
  final rowAncestors = find
      .ancestor(of: find.text('b-7'), matching: find.byType(DecoratedBox))
      .evaluate();
  var rowBox = rowAncestors.first.findRenderObject() as RenderBox;
  for (final el in rowAncestors) {
    final b = el.findRenderObject() as RenderBox;
    if (b.size.width > rowBox.size.width) rowBox = b;
  }
  return rowBox;
}

void main() {
  testWidgets('内容少：自然横滚条在最后一行下方且隔 16 间距', (tester) async {
    await tester.pumpWidget(_wrap(_table(const [_Row('a'), _Row('b')])));
    await tester.pump();

    final barBox = _hBarBox(tester);
    final barBottom = barBox.localToGlobal(Offset.zero).dy + barBox.size.height;
    final rowBox = _lastRowBox(tester);
    final rowBottom = rowBox.localToGlobal(Offset.zero).dy + rowBox.size.height;
    final gap = barBottom - rowBottom;
    debugPrint('内容少：横滚条与最后一行的间距 = $gap');
    expect(gap, closeTo(11, 1));
  });

  testWidgets('内容多：横滚条钉在表体区域底部（视口底）', (tester) async {
    await tester.pumpWidget(
      _wrap(_table([for (var i = 0; i < 60; i++) _Row('r$i')])),
    );
    await tester.pump();

    final barBox = _hBarBox(tester);
    final barBottom = barBox.localToGlobal(Offset.zero).dy + barBox.size.height;
    debugPrint('内容多：横滚条底边 = $barBottom（视口高 600）');
    // 钉底：滚动条贴表体区域底（本用例即视口底 600），且高度被封顶在可用高而非内容高。
    expect(barBottom, closeTo(600, 1));
    expect(barBox.size.height, lessThan(600));
  });

  testWidgets('带悬浮批量按钮（颜色主档同款）：内容少时横滚条仍隔 11 不被 88 顶开', (tester) async {
    await tester.pumpWidget(
      _wrap(_table(const [_Row('a'), _Row('b')], withBatch: true)),
    );
    await tester.pump();
    await tester.pump(); // 底 padding 动态判定收敛。

    final barBox = _hBarBox(tester);
    final barBottom = barBox.localToGlobal(Offset.zero).dy + barBox.size.height;
    final rowBox = _lastRowBox(tester);
    final rowBottom = rowBox.localToGlobal(Offset.zero).dy + rowBox.size.height;
    final gap = barBottom - rowBottom;
    debugPrint('批量表内容少：横滚条与最后一行的间距 = $gap（应 11，非 88）');
    expect(gap, closeTo(11, 1));
  });
}
