// MasterDataTableView 横向滚动条位置行为回归：
// - 内容少（表体不超可用高）：横滚条在最后一行下方，底边距末行 11；
// - 内容多（表体超高）：横滚条钉在表体区域底部（视口底），不随内容沉底。
// 与 uten_editable_grid_hscrollbar_test 同款规格，锁定两张表行为一致。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(this.id);
  final String id;
}

MasterDataTableView<_Row> _table(
  List<_Row> items, {
  bool withBatch = false,
  double bottomContentPadding = 0,
}) {
  return MasterDataTableView<_Row>(
    bottomContentPadding: bottomContentPadding,
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
RenderBox _lastRowBox(WidgetTester tester, {String text = 'b-7'}) {
  final rowAncestors = find
      .ancestor(of: find.text(text), matching: find.byType(DecoratedBox))
      .evaluate();
  var rowBox = rowAncestors.first.findRenderObject() as RenderBox;
  for (final el in rowAncestors) {
    final b = el.findRenderObject() as RenderBox;
    if (b.size.width > rowBox.size.width) rowBox = b;
  }
  return rowBox;
}

void main() {
  testWidgets('内容少：自然横滚条底边距最后一行 11', (tester) async {
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

  testWidgets('带悬浮批量按钮（颜色主档同款）：内容少时横滚条仍隔 11 不被 200 留白顶开', (tester) async {
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
    debugPrint('批量表内容少：横滚条与最后一行的间距 = $gap（应 11，非 200）');
    expect(gap, closeTo(11, 1));
  });
  testWidgets('外置悬浮按钮留白可以移除并恢复自然横滚条', (tester) async {
    await tester.pumpWidget(
      _wrap(_table(const [_Row('a'), _Row('b')], bottomContentPadding: 200)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListView>(find.byType(ListView)).padding,
      const EdgeInsets.only(bottom: 200),
    );
    var bar = _hBarBox(tester);
    var row = _lastRowBox(tester);
    expect(bar.size.height, 11);
    expect(
      bar.localToGlobal(Offset.zero).dy +
          bar.size.height -
          row.localToGlobal(Offset.zero).dy -
          row.size.height,
      closeTo(11, 1),
    );

    await tester.pumpWidget(_wrap(_table(const [_Row('a'), _Row('b')])));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListView>(find.byType(ListView)).padding,
      const EdgeInsets.only(bottom: 11),
    );
    bar = _hBarBox(tester);
    row = _lastRowBox(tester);
    expect(bar.size.height, greaterThan(11));
    expect(
      bar.localToGlobal(Offset.zero).dy +
          bar.size.height -
          row.localToGlobal(Offset.zero).dy -
          row.size.height,
      closeTo(11, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('悬浮操作移除后撤掉旧留白，短表横滚条仍贴末行', (tester) async {
    await tester.pumpWidget(
      _wrap(_table(const [_Row('a'), _Row('b')], withBatch: true)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListView>(find.byType(ListView)).padding,
      const EdgeInsets.only(bottom: 200),
    );
    await tester.pumpWidget(_wrap(_table(const [_Row('a'), _Row('b')])));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListView>(find.byType(ListView)).padding,
      const EdgeInsets.only(bottom: 11),
    );
    expect(_hBarBox(tester).size.height, greaterThan(11));
    expect(tester.takeException(), isNull);
  });

  testWidgets('长表滚到底保留 200 留白，横滚条跟随实际末行', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _table([for (var i = 0; i < 60; i++) _Row('r$i')], withBatch: true),
      ),
    );
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    final row = _lastRowBox(tester, text: 'r59-7');
    final rowBottom = row.localToGlobal(Offset.zero).dy + row.size.height;
    expect(
      tester.getRect(find.byType(ListView)).bottom - rowBottom,
      closeTo(200, 1),
    );
    final bar = _hBarBox(tester);
    expect(
      bar.localToGlobal(Offset.zero).dy + bar.size.height - rowBottom,
      closeTo(11, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('悬浮横滚条与表头表体同步，切换留白保留横向位置', (tester) async {
    Widget page(double padding) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          height: 400,
          child: _table(const [
            _Row('a'),
            _Row('b'),
          ], bottomContentPadding: padding),
        ),
      ),
    );
    await tester.pumpWidget(page(0));
    await tester.pumpAndSettle();
    final body = tester
        .widgetList<Scrollbar>(find.byType(Scrollbar))
        .last
        .controller!;
    body.jumpTo(100);
    await tester.pumpAndSettle();
    await tester.pumpWidget(page(200));
    await tester.pumpAndSettle();
    final overlay = tester
        .widgetList<Scrollbar>(find.byType(Scrollbar))
        .last
        .controller!;
    expect(overlay.offset, closeTo(100, 1));
    overlay.jumpTo(160);
    await tester.pumpAndSettle();
    final horizontal = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((scroll) => scroll.scrollDirection == Axis.horizontal);
    expect(horizontal, hasLength(3));
    for (final scroll in horizontal) {
      expect(scroll.controller!.offset, closeTo(160, 1));
    }
    await tester.pumpWidget(page(0));
    await tester.pumpAndSettle();
    final natural = tester
        .widgetList<Scrollbar>(find.byType(Scrollbar))
        .last
        .controller!;
    expect(natural.offset, closeTo(160, 1));
    expect(tester.takeException(), isNull);
  });
}
