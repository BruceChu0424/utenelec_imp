// UtenEditableGrid 列宽随内容自动加宽的行为测试：
// - 初始短内容不撑宽（保持列定义初始宽）；
// - 敲入长内容自动加宽、封顶 480；删短内容只增不减；
// - 初始行 / 整批换行（replaceAll/addRow）整体量宽兜底；
// - 手动拖拽（含缩小）后锁定用户宽度，不再随内容自动加宽。
import 'package:flutter/gestures.dart';
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

const _colWidth = 120.0;
const _cellPadX = 16.0; // 格内左右内边距 8×2
const _maxColWidth = 480.0;

/// 最近一次单元构建拿到的最大宽（= 当前列宽 - 格内边距），LayoutBuilder 捕获。
double? cellMaxWidth;

UtenEditableGrid<_NoteRow> _grid(UtenEditableGridController<_NoteRow> c) {
  return UtenEditableGrid<_NoteRow>(
    controller: c,
    columns: [
      EditableGridColumn<_NoteRow>(
        key: 'note',
        label: '备注',
        width: _colWidth,
        textOf: (r) => r.note.text,
        listenableOf: (r) => r.note,
        cellBuilder: (context, row) => LayoutBuilder(
          builder: (context, constraints) {
            cellMaxWidth = constraints.maxWidth;
            return TextField(
              controller: row.note,
              decoration: const InputDecoration(isDense: true),
            );
          },
        ),
      ),
    ],
    createBlankRow: () => _NoteRow(),
  );
}

Widget _wrap(UtenEditableGrid<_NoteRow> grid) => MaterialApp(
  home: Scaffold(body: ListView(children: [grid])),
);

const _long = '很长很长的备注内容凭空变长'; // 12 个全角字 ×8 = 96 字，必超 480 封顶

void main() {
  testWidgets('初始短内容不撑宽，保持列定义初始宽', (tester) async {
    final c = UtenEditableGridController<_NoteRow>(initial: [_NoteRow('ab')]);
    await tester.pumpWidget(_wrap(_grid(c)));
    expect(cellMaxWidth, closeTo(_colWidth - _cellPadX, 0.5));
  });

  testWidgets('敲入长内容自动加宽到封顶；删短后只增不减', (tester) async {
    final c = UtenEditableGridController<_NoteRow>(initial: [_NoteRow('ab')]);
    await tester.pumpWidget(_wrap(_grid(c)));
    expect(cellMaxWidth, closeTo(_colWidth - _cellPadX, 0.5));

    await tester.enterText(find.byType(TextField), _long * 8);
    await tester.pump();
    expect(cellMaxWidth, closeTo(_maxColWidth - _cellPadX, 0.5));

    // 只增不减：内容删短后列不缩回去。
    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump();
    expect(cellMaxWidth, closeTo(_maxColWidth - _cellPadX, 0.5));
  });

  testWidgets('初始长内容行 / 整批换行(addRow/replaceAll)整体量宽兜底', (tester) async {
    final c = UtenEditableGridController<_NoteRow>(initial: [_NoteRow('短')]);
    await tester.pumpWidget(_wrap(_grid(c)));
    expect(cellMaxWidth, closeTo(_colWidth - _cellPadX, 0.5));

    c.addRow(_NoteRow(_long * 8));
    await tester.pump();
    expect(cellMaxWidth, closeTo(_maxColWidth - _cellPadX, 0.5));

    // 整批替换后重新量（新行短，但只增不减 → 维持封顶宽）。
    c.replaceAll([_NoteRow('短')]);
    await tester.pump();
    expect(cellMaxWidth, closeTo(_maxColWidth - _cellPadX, 0.5));
  });

  testWidgets('手动拖拽缩小后锁定：停在该宽度，不再随内容自动加宽', (tester) async {
    final c = UtenEditableGridController<_NoteRow>(initial: [_NoteRow('ab')]);
    await tester.pumpWidget(_wrap(_grid(c)));
    final initial = cellMaxWidth!;

    // 抓列右边界竖线（贴列右边界、半溢出 4px 的命中区，Stack 裁掉溢出半区后
    // 可点的是边界内侧 4px）向左拖 → 手动缩小生效。列右边界由表头文本位置推算：
    // 表头内边距 12 + 当前列宽（cellMaxWidth + 格内边距 16）。
    // 用鼠标指针：resize 手柄本身即桌面交互（悬停显 resize 光标）；触屏指针下
    // 手柄与表头横向滚动区的手势竞技由滚动区胜出（与 MasterDataTableView 同款既有行为）。
    final head = tester.renderObject(find.text('备注')) as RenderBox;
    final headLeft = head.localToGlobal(Offset.zero).dx;
    final colRight = headLeft - 12 + cellMaxWidth! + _cellPadX;
    final gesture = await tester.startGesture(
      Offset(
        colRight - 2,
        head.localToGlobal(Offset(0, head.size.height / 2)).dy,
      ),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-60, 0));
    await gesture.up();
    await tester.pump();

    final locked = cellMaxWidth!;
    expect(locked, lessThan(initial)); // 缩小生效
    expect(locked, greaterThan(48 - _cellPadX)); // 下限 48 防拖没

    // 锁定后即使输入超长内容也不再自动加宽。
    await tester.enterText(find.byType(TextField), _long * 8);
    await tester.pump();
    expect(cellMaxWidth, locked);
  });
}
