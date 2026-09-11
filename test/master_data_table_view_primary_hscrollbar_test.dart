// MasterDataTableView primary 模式（联动折叠页，如货品资料）横滚条位置行为回归：
// - 内容少：横滚条贴最后一行下方（隔 16），不再钉在联动区底/屏幕底；
// - 内容多：横滚条钉在表体区底；
// - 顶部卡片折叠手势不受覆盖层影响（表格上上滑仍能收起卡片）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

String _identity(String v) => v;

/// harness 视口高：须 ≥ UtenCollapsingHeaderScrollView 的矮视口回退阈值（600）
/// 且给 body 留够 compactBodyMinHeight(360)，否则组件走「整页滚 + body 定高」
/// 回退（2026-09-11 矮视口/挤扁回退），本文件要验的正是联动模式下的横滚条与
/// 折叠手势。
const double _pageHeight = 700;

/// 默认测试窗口只有 800x600，装不下 [_pageHeight] 的 harness：显式放大到 800x1000。
void _setView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _page(List<String> items, {bool withBatch = false}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 640,
        height: _pageHeight,
        child: UtenCollapsingHeaderScrollView(
          collapsingHeader: const SizedBox(
            height: 60,
            child: Center(child: Text('分类卡片')),
          ),
          body: Column(
            children: [
              const SizedBox(height: 40, child: Center(child: Text('工具行'))),
              Expanded(
                child: MasterDataTableView<String>(
                  primary: true,
                  columns: [
                    for (var i = 0; i < 6; i++)
                      MasterColumnDef<String>(
                        key: 'c$i',
                        label: '列$i',
                        width: 160,
                        value: _identity,
                      ),
                  ],
                  items: items,
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  // 货品资料同款：多选 + 悬浮批量按钮（右下角）。
                  selectable: withBatch,
                  idOf: withBatch ? _identity : null,
                  batchActionsBuilder: withBatch
                      ? (context, ids) => const [Text('批量操作')]
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 覆盖层横滚条 = 高度 16 的 Scrollbar（竖向条与表同高）。
RenderBox _overlayBarBox(WidgetTester tester) {
  RenderBox? box;
  for (final el in find.byType(Scrollbar).evaluate()) {
    final b = el.findRenderObject() as RenderBox;
    if (b.size.height <= 20) box = b;
  }
  expect(box, isNotNull, reason: '应存在覆盖层横滚条');
  return box!;
}

/// 最后一行底边：末行文本向上找最宽的祖先 DecoratedBox（= 整行，含底边线）。
RenderBox _lastRowBox(WidgetTester tester, String lastText) {
  final ancestors = find
      .ancestor(of: find.text(lastText), matching: find.byType(DecoratedBox))
      .evaluate();
  var rowBox = ancestors.first.findRenderObject() as RenderBox;
  for (final el in ancestors) {
    final b = el.findRenderObject() as RenderBox;
    if (b.size.width > rowBox.size.width) rowBox = b;
  }
  return rowBox;
}

void main() {
  testWidgets('内容少：横滚条贴最后一行下方（隔 16），不钉屏幕底', (tester) async {
    _setView(tester);
    await tester.pumpWidget(_page(['ROW-0', 'ROW-1', 'ROW-2']));
    await tester.pump(); // post-frame 量内容高并定位覆盖层。

    final bar = _overlayBarBox(tester);
    final barTop = bar.localToGlobal(Offset.zero).dy;
    final row = _lastRowBox(tester, 'ROW-2');
    final rowBottom = row.localToGlobal(Offset.zero).dy + row.size.height;
    debugPrint(
      '内容少：横滚条 top=$barTop，最后一行底=$rowBottom（条 box 占位 [行底, 行底+11]，滑块上缘距行底约 1px）',
    );
    expect(barTop, closeTo(rowBottom, 1.5));
    // 不在屏幕底（_pageHeight-16）。
    expect(barTop, lessThan(_pageHeight - 16 - 20));
  });

  testWidgets('内容多：横滚条钉在表体区底（视口底）', (tester) async {
    _setView(tester);
    await tester.pumpWidget(_page([for (var i = 0; i < 60; i++) 'ROW-$i']));
    await tester.pump();

    final bar = _overlayBarBox(tester);
    final barTop = bar.localToGlobal(Offset.zero).dy;
    debugPrint('内容多：横滚条 top=$barTop，期望 ${_pageHeight - 11}');
    expect(barTop, closeTo(_pageHeight - 11, 1));
  });

  testWidgets('折叠手势不受影响：表格上上滑仍收起顶部卡片', (tester) async {
    _setView(tester);
    await tester.pumpWidget(_page(['ROW-0', 'ROW-1', 'ROW-2']));
    await tester.pump();

    final toolbarBefore = tester.renderObject(find.text('工具行')) as RenderBox;
    final before = toolbarBefore.localToGlobal(Offset.zero).dy;

    // 在表格区上滑（拖到顶，把 60 高的卡片收完）。
    await tester.timedDrag(
      find.text('ROW-1').first,
      const Offset(0, -220),
      const Duration(milliseconds: 400),
    );
    await tester.pumpAndSettle();

    final toolbarAfter = tester.renderObject(find.text('工具行')) as RenderBox;
    final after = toolbarAfter.localToGlobal(Offset.zero).dy;
    debugPrint('折叠手势：工具行 y $before → $after（卡片收起后应顶到 0）');
    expect(after, lessThan(before - 30), reason: '卡片应收起，工具行上移');
  });

  testWidgets('带悬浮批量按钮（货品资料同款）：内容少时横滚条仍贴末行', (tester) async {
    _setView(tester);
    await tester.pumpWidget(
      _page(['ROW-0', 'ROW-1', 'ROW-2'], withBatch: true),
    );
    await tester.pump();
    await tester.pump(); // 底 padding 动态判定收敛。

    final bar = _overlayBarBox(tester);
    final barTop = bar.localToGlobal(Offset.zero).dy;
    final row = _lastRowBox(tester, 'ROW-2');
    final rowBottom = row.localToGlobal(Offset.zero).dy + row.size.height;
    debugPrint('批量表内容少：横滚条 top=$barTop，最后一行底=$rowBottom（应贴合，非 +88）');
    expect(barTop, closeTo(rowBottom, 1.5));
    expect(barTop, lessThan(rowBottom + 20), reason: '不受悬浮批量 88 让位影响');
  });
}
