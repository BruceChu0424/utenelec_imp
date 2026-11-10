// UtenEditableGrid 横向滚动条位置行为诊断：
// - 内容少（表体不超视口高）：自然横滚条应在最后一行下方、且与最后一行有间距；
// - 内容多（表体超视口高）：横滚条钉在视口底部（覆盖层），不随内容沉底。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';

import '../support/scrollbar_pointer.dart';

class _NoteRow extends EditableGridRow {
  final TextEditingController note = TextEditingController();

  _NoteRow([String text = '']) {
    note.text = text;
  }

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }
}

UtenEditableGrid<_NoteRow> _grid(
  UtenEditableGridController<_NoteRow> c, {
  bool longHeaders = false,
}) {
  return UtenEditableGrid<_NoteRow>(
    controller: c,
    columns: [
      for (var i = 0; i < 8; i++)
        EditableGridColumn<_NoteRow>(
          key: 'col$i',
          label: longHeaders ? '列$i／需要查看的完整字段名称' : '列$i',
          width: 160,
          cellBuilder: (context, row) => TextField(
            controller: row.note,
            decoration: const InputDecoration(isDense: true),
          ),
        ),
    ],
    createBlankRow: () => _NoteRow(),
  );
}

Widget _wrap(UtenEditableGrid<_NoteRow> grid) => MaterialApp(
  home: Scaffold(body: ListView(children: [grid])),
);

// The desktop MaterialApp may add a vertical scrollbar to the host ListView.
// Assert ownership/count only for the horizontal business canvas.
Finder _horizontalBars() => find.byWidgetPredicate((widget) {
  if (widget is! Scrollbar) return false;
  final controller = widget.controller;
  return controller != null &&
      controller.hasClients &&
      controller.positions.every(
        (position) => position.axis == Axis.horizontal,
      );
});

void main() {
  testWidgets('空编辑表保留超宽表头横滚且空态保持在可视区', (tester) async {
    final c = UtenEditableGridController<_NoteRow>();
    await tester.pumpWidget(_wrap(_grid(c, longHeaders: true)));
    await tester.pumpAndSettle();
    final bar = _horizontalBars();
    expect(bar, findsOneWidget);
    final horizontal = tester.widget<Scrollbar>(bar).controller!;
    expect(horizontal.position.maxScrollExtent, greaterThan(0));
    await dragHorizontalScrollbarThumb(tester, bar);
    expect(horizontal.offset, greaterThan(0), reason: '实际拖动零行编辑表滑块必须移动列头');
    horizontal.jumpTo(320);
    await tester.pumpAndSettle();
    expect(find.text('暂无明细，点击下方按钮添加').hitTestable(), findsOneWidget);
    expect(find.text('列0／需要查看的完整字段名称'), findsOneWidget);
    c.addRow(_NoteRow('草稿不丢失'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Scrollbar>(_horizontalBars()).controller!.offset,
      closeTo(320, 1),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
  for (final brightness in Brightness.values) {
    testWidgets('横滚选中行冻结勾选列不透字 $brightness', (tester) async {
      final controller = UtenEditableGridController<_NoteRow>(
        initial: [_NoteRow('底层文字不可透出')],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(body: ListView(children: [_grid(controller)])),
        ),
      );
      await tester.pumpAndSettle();
      controller.selectAll();
      await tester.pumpAndSettle();
      var frozen = tester
          .widgetList<UtenFrozenLeadingColumn>(
            find.byType(UtenFrozenLeadingColumn),
          )
          .where((widget) => widget.cell is ColoredBox)
          .toList();
      expect(frozen, isNotEmpty);
      frozen.last.horizontal.jumpTo(200);
      await tester.pumpAndSettle();
      frozen = tester
          .widgetList<UtenFrozenLeadingColumn>(
            find.byType(UtenFrozenLeadingColumn),
          )
          .where((widget) => widget.cell is ColoredBox)
          .toList();
      for (final column in frozen) {
        expect(
          (column.cell as ColoredBox).color.a,
          1,
          reason: '冻结列必须遮住滚过的物料文字',
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }
  testWidgets('内容少：自然横滚条在最后一行下方且有间距', (tester) async {
    final c = UtenEditableGridController<_NoteRow>(
      initial: [_NoteRow('r0'), _NoteRow('r1')],
    );
    await tester.pumpWidget(_wrap(_grid(c)));

    // 自然横滚条 = 包着横向 SingleChildScrollView 的 Scrollbar（钉底条此刻 Offstage）。
    final bars = _horizontalBars();
    expect(bars.evaluate().length, 1, reason: '内容不超高时只有自然滚动条');
    final barBox = tester.renderObject(bars) as RenderBox;
    final barBottom = barBox.localToGlobal(Offset.zero).dy + barBox.size.height;

    // 最后一行底边：末行删除按钮向上找最宽的祖先 DecoratedBox（= 整行，含底边线）。
    // 不能拿竖向 ListView 的 box 量：它自带 bottom padding，会与滚动条同步位移。
    final rowAncestors = find
        .ancestor(
          of: find.byTooltip('删除该行').last,
          matching: find.byType(DecoratedBox),
        )
        .evaluate();
    RenderBox rowBox = rowAncestors.first.findRenderObject() as RenderBox;
    for (final el in rowAncestors) {
      final b = el.findRenderObject() as RenderBox;
      if (b.size.width > rowBox.size.width) rowBox = b;
    }
    final rowBottom = rowBox.localToGlobal(Offset.zero).dy + rowBox.size.height;
    final gap = barBottom - rowBottom;
    // 期望：滚动条底边低于最后一行底边 16（紧贴末行：滑块上缘距行底约 1px（box 底距行底 11 = 滑块厚 10 + 1））。
    debugPrint('内容少：横滚条与最后一行的间距 = $gap');
    expect(gap, closeTo(11, 1));
  });

  testWidgets('内容多：横滚条钉在视口底部', (tester) async {
    final c = UtenEditableGridController<_NoteRow>(
      initial: [for (var i = 0; i < 60; i++) _NoteRow()],
    );
    await tester.pumpWidget(_wrap(_grid(c)));
    // 两轮 post-frame：第 1 帧量几何并钉底；第 2 帧表头占位高修正后表体下移，
    // 钉底位置随后一帧追平（组件自校正，多泵一帧等它收敛）。
    await tester.pump();
    await tester.pump();

    final bars = _horizontalBars();
    debugPrint('内容多：可见 Scrollbar 数 = ${bars.evaluate().length}');
    expect(bars.evaluate().length, 2, reason: '自然条 + 钉底条（Offstage 已揭开会出现在树里）');

    // 钉底条：高度 11、贴视口底（600 - 11 = 589）。
    RenderBox? pinnedBox;
    for (final el in bars.evaluate()) {
      final box = el.findRenderObject() as RenderBox;
      if (box.size.height <= 20) pinnedBox = box;
    }
    expect(pinnedBox, isNotNull, reason: '应存在钉底横滚条');
    final top = pinnedBox!.localToGlobal(Offset.zero).dy;
    debugPrint('内容多：钉底条 top = $top，期望 ${600 - 11}');
    expect(top, closeTo(600 - 11, 1));
  });
}
