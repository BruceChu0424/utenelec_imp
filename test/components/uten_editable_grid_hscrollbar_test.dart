// UtenEditableGrid 横向滚动条位置行为诊断：
// - 内容少（表体不超视口高）：自然横滚条应在最后一行下方、且与最后一行有间距；
// - 内容多（表体超视口高）：横滚条钉在视口底部（覆盖层），不随内容沉底。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';

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

UtenEditableGrid<_NoteRow> _grid(UtenEditableGridController<_NoteRow> c) {
  return UtenEditableGrid<_NoteRow>(
    controller: c,
    columns: [
      for (var i = 0; i < 8; i++)
        EditableGridColumn<_NoteRow>(
          key: 'col$i',
          label: '列$i',
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

void main() {
  testWidgets('内容少：自然横滚条在最后一行下方且有间距', (tester) async {
    final c = UtenEditableGridController<_NoteRow>(
      initial: [_NoteRow('r0'), _NoteRow('r1')],
    );
    await tester.pumpWidget(_wrap(_grid(c)));

    // 自然横滚条 = 包着横向 SingleChildScrollView 的 Scrollbar（钉底条此刻 Offstage）。
    final bars = find.byType(Scrollbar);
    expect(bars.evaluate().length, 1, reason: '内容不超高时只有自然滚动条');
    final barBox = tester.renderObject(bars) as RenderBox;
    final barBottom = barBox.localToGlobal(Offset.zero).dy + barBox.size.height;

    // 最后一行底边：末行删除按钮向上找最宽的祖先 DecoratedBox（= 整行，含底边线）。
    // 不能拿竖向 ListView 的 box 量：它自带 bottom padding，会与滚动条同步位移。
    final rowAncestors = find
        .ancestor(
          of: find.byType(IconButton).last,
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

    final bars = find.byType(Scrollbar);
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
