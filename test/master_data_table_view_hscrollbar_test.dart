// MasterDataTableView 横向滚动条位置行为回归：
// - 内容少（表体不超可用高）：横滚条在最后一行下方，底边距末行 11；
// - 内容多（表体超高）：横滚条钉在表体区域底部（视口底），不随内容沉底。
// 与 uten_editable_grid_hscrollbar_test 同款规格，锁定两张表行为一致。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(this.id);
  final String id;
}

MasterDataTableView<_Row> _table(
  List<_Row> items, {
  bool withBatch = false,
  double bottomContentPadding = 0,
  Set<String> selectedIds = const {},
  ValueChanged<Set<String>>? onSelectedIdsChanged,
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
    selectedIds: selectedIds,
    onSelectedIdsChanged: onSelectedIdsChanged,
    idOf: withBatch ? (item) => item.id : null,
    batchActionsBuilder: withBatch
        ? (context, ids) => const [Text('批量操作')]
        : null,
  );
}

Widget _wrap(MasterDataTableView<_Row> table) =>
    MaterialApp(home: Scaffold(body: table));

/// Chrome/悬浮操作有各自的竖向滚动条；只定位控制业务横向轴的滚动条。
Finder _horizontalBars() => find.byWidgetPredicate((widget) {
  if (widget is! Scrollbar) return false;
  final controller = widget.controller;
  return controller != null &&
      controller.hasClients &&
      controller.positions.every(
        (position) => position.axis == Axis.horizontal,
      );
});

ScrollController _horizontalController(WidgetTester tester) =>
    tester.widget<Scrollbar>(_horizontalBars()).controller!;

RenderBox _hBarBox(WidgetTester tester) {
  final bars = _horizontalBars().evaluate().toList();
  expect(bars.length, 1, reason: '业务表格只有一个横向滚动条');
  return bars[0].findRenderObject() as RenderBox;
}

/// 最后一行底边：末行末格文本的业务行同时拥有底分隔线与末列右边界。
/// 整表 surface 也可能是更宽的 DecoratedBox，不能拿它的底边当作末行。
/// 纯展示行不挂 InkWell，锚点用末行最后一列的单元格文本。
RenderBox _lastRowBox(WidgetTester tester, {String text = 'b-7'}) {
  final row = find.ancestor(
    of: find.text(text),
    matching: find.byWidgetPredicate((widget) {
      if (widget is! DecoratedBox || widget.decoration is! BoxDecoration) {
        return false;
      }
      final border = (widget.decoration as BoxDecoration).border;
      return border is Border &&
          border.bottom.style == BorderStyle.solid &&
          border.bottom.width > 0 &&
          border.top == BorderSide.none &&
          border.left == BorderSide.none &&
          border.right == border.bottom;
    }),
  );
  expect(row, findsOneWidget, reason: '末格应只属于一条带行分隔线的业务行');
  return tester.renderObject<RenderBox>(row);
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
      EdgeInsets.only(
        bottom:
            tester.getSize(find.byType(UtenFloatingActionGroup)).height +
            16 +
            11,
      ),
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

  testWidgets('长表滚到底保留实际操作组让位，横滚条跟随实际末行', (tester) async {
    var selected = <String>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => _table(
              [for (var i = 0; i < 60; i++) _Row('r$i')],
              withBatch: true,
              selectedIds: selected,
              onSelectedIdsChanged: (next) => update(() => selected = next),
            ),
          ),
        ),
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
      closeTo(
        tester.getSize(find.byType(UtenFloatingActionGroup)).height + 16 + 11,
        1,
      ),
    );
    final bar = _hBarBox(tester);
    expect(
      bar.localToGlobal(Offset.zero).dy + bar.size.height - rowBottom,
      closeTo(11, 1),
    );

    // Reset only the test setup. The next end-of-list visit uses real, bounded
    // user drags; the original jumpTo scrollbar-spacing assertion above stays.
    position.jumpTo(0);
    await tester.pumpAndSettle();
    for (var drag = 0; drag < 20 && position.extentAfter > 0.1; drag++) {
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.1));
    final visibleRow = _lastRowBox(tester, text: 'r59-7');
    final visibleTop = visibleRow.localToGlobal(Offset.zero).dy;
    final visibleBottom = visibleTop + visibleRow.size.height;
    final listRect = tester.getRect(find.byType(ListView));
    final groupRect = tester.getRect(find.byType(UtenFloatingActionGroup));
    expect(visibleTop, greaterThanOrEqualTo(listRect.top));
    expect(visibleBottom, lessThanOrEqualTo(groupRect.top - 11 + 0.1));
    final lastCell = find.text('r59-0');
    expect(lastCell.hitTestable(), findsOneWidget);
    await tester.tap(lastCell);
    await tester.pumpAndSettle();
    expect(selected, {'r59'});
    expect(find.text('已选 1 项'), findsOneWidget);

    final checkboxElement = find
        .byType(Checkbox)
        .hitTestable()
        .evaluate()
        .singleWhere((element) {
          final finder = find.byElementPredicate(
            (candidate) => identical(candidate, element),
          );
          final center = tester.getCenter(finder);
          return center.dy >= visibleTop && center.dy <= visibleBottom;
        });
    final checkbox = find.byElementPredicate(
      (element) => identical(element, checkboxElement),
    );
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    expect(selected, {'r59'});
    final clear = find.byKey(const Key('master-table-clear-selection'));
    expect(clear.hitTestable(), findsOneWidget);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(find.text('已选 0 项'), findsOneWidget);

    final horizontal = _horizontalController(tester);
    final before = horizontal.offset;
    await tester.drag(find.text('r59-2'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(horizontal.offset, greaterThan(before + 50));
    for (final scroll
        in tester
            .widgetList<SingleChildScrollView>(
              find.byType(SingleChildScrollView),
            )
            .where((scroll) => scroll.scrollDirection == Axis.horizontal)) {
      expect(scroll.controller!.offset, closeTo(horizontal.offset, 1));
    }
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
    final body = _horizontalController(tester);
    body.jumpTo(100);
    await tester.pumpAndSettle();
    await tester.pumpWidget(page(200));
    await tester.pumpAndSettle();
    final overlay = _horizontalController(tester);
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
    final natural = _horizontalController(tester);
    expect(natural.offset, closeTo(160, 1));
    expect(tester.takeException(), isNull);
  });

  // 2026-10-10 空表口径：0 数据行且 0 前导分组行时表格骨架（工具条+表头）仍在，
  // 但内容宽=列宽和>视口会让 thumb 恒显成噪音 → 空表不画横向滚动条；
  // 加载/错误态的提示行同理。有数据时行为与原来完全一致（回归保护）。
  testWidgets('空表（覆盖层路径）：不渲染横向滚动条', (tester) async {
    await tester.pumpWidget(_wrap(_table(const [], bottomContentPadding: 200)));
    await tester.pumpAndSettle();

    expect(
      _horizontalBars(),
      findsNothing,
      reason: '空表（0 行、无前导分组）不应有框架横滚条（覆盖层分支不挂）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('空表补一行数据后覆盖层横滚条恢复（回归保护）', (tester) async {
    await tester.pumpWidget(_wrap(_table(const [], bottomContentPadding: 200)));
    await tester.pumpAndSettle();
    expect(_horizontalBars(), findsNothing);

    await tester.pumpWidget(
      _wrap(_table(const [_Row('a')], bottomContentPadding: 200)),
    );
    await tester.pumpAndSettle();
    // 恢复后恰好一个业务横向滚动条。
    expect(_hBarBox(tester).size.height, 11);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空表（流内路径）：不渲染横向滚动条，来数据后恢复', (tester) async {
    await tester.pumpWidget(_wrap(_table(const [])));
    await tester.pumpAndSettle();
    expect(_horizontalBars(), findsNothing, reason: '空表不包流内横向 Scrollbar');

    await tester.pumpWidget(_wrap(_table(const [_Row('a')])));
    await tester.pumpAndSettle();
    expect(_hBarBox(tester).size.height, greaterThanOrEqualTo(11));
    expect(tester.takeException(), isNull);
  });
}
