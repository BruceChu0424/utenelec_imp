// UtenEditableGrid 行级右键/长按操作菜单的行为测试（2026-09-03 接入）：
// - 可编辑模式长按/右击未勾选行 → 先把选中集替换为仅该行再弹菜单（文件管理器语义）；
//   已勾选多行时长按其中一行 → 保留多选，菜单作用于整组；
// - 菜单条目与操作条同一套 controller 逻辑：复制选中/粘贴（追加表尾）/
//   批量粘贴（份数对话框）/在上方插入空行/删除选中（确认弹窗）；
// - 缓冲为空时粘贴置灰；cloneRow 未提供时不显复制粘贴组；
// - 只选/任务模式（showAddRow=false）不挂菜单。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';

class _Row extends EditableGridRow {
  _Row(this.name);

  final String name;

  @override
  void dispose() {}
}

UtenEditableGrid<_Row> _grid(
  UtenEditableGridController<_Row> c, {
  bool showAddRow = true,
  bool selectable = false,
  bool withClone = true,
}) {
  return UtenEditableGrid<_Row>(
    controller: c,
    columns: [
      EditableGridColumn<_Row>(
        key: 'name',
        label: '名称',
        width: 120,
        cellBuilder: (context, row) => Text(row.name),
      ),
    ],
    createBlankRow: () => _Row('新行'),
    cloneRow: withClone ? (r) => _Row(r.name) : null,
    showAddRow: showAddRow,
    selectable: selectable,
  );
}

Widget _wrap(UtenEditableGrid<_Row> grid) => MaterialApp(
  home: Scaffold(body: ListView(children: [grid])),
);

/// 以鼠标右键点在 [finder] 中心（桌面触发路径；onSecondaryTapDown 在按下即触发）。
Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pump();
}

void main() {
  testWidgets('长按未勾选行 → 选中集替换为仅该行并弹菜单；已勾选多行则保留多选', (tester) async {
    final r1 = _Row('行1');
    final r2 = _Row('行2');
    final c = UtenEditableGridController<_Row>(initial: [r1, r2]);
    await tester.pumpWidget(_wrap(_grid(c)));

    await tester.longPress(find.text('行2'));
    await tester.pump();
    // 「在上方插入空行」为菜单独有条目（操作条无），作菜单已弹的判据。
    expect(find.text('在上方插入空行'), findsOneWidget);
    expect(c.isSelected(r2), isTrue);
    expect(c.isSelected(r1), isFalse);

    // 关菜单（点外部）。
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();

    // 勾选两行后长按其中一行：保留多选，菜单计数为整组（2）。
    c.selectAll();
    await tester.pump();
    await tester.longPress(find.text('行1'));
    await tester.pump();
    expect(find.text('删除选中 (2)'), findsOneWidget);
    expect(c.isSelected(r1) && c.isSelected(r2), isTrue);
  });

  testWidgets('右击行同样出菜单（桌面触发路径）', (tester) async {
    final c = UtenEditableGridController<_Row>(initial: [_Row('行1')]);
    await tester.pumpWidget(_wrap(_grid(c)));

    await _rightClick(tester, find.text('行1'));
    expect(find.text('删除选中 (1)'), findsOneWidget);
  });

  testWidgets('复制 → 粘贴：缓冲为空时粘贴置灰，复制后粘贴追加到表尾', (tester) async {
    final r1 = _Row('行1');
    final c = UtenEditableGridController<_Row>(initial: [r1]);
    await tester.pumpWidget(_wrap(_grid(c)));

    await tester.longPress(find.text('行1'));
    await tester.pump();
    // 初始无缓冲：操作条不显「粘贴」（hasBuffer=false），唯一的「粘贴」是菜单项（置灰）。
    final pasteDisabled = tester
        .widget<InkWell>(
          find.ancestor(of: find.text('粘贴'), matching: find.byType(InkWell)),
        )
        .onTap;
    expect(pasteDisabled, isNull);

    // .last = 覆盖层菜单项（「复制选中 (n)」与操作条按钮同文案，菜单后挂在其上）。
    await tester.tap(find.text('复制选中 (1)').last);
    await tester.pump();
    expect(c.hasBuffer, isTrue);

    await tester.longPress(find.text('行1'));
    await tester.pump();
    await tester.tap(find.text('粘贴').last);
    await tester.pump();
    // 粘贴统一追加表尾：两行，末行是新克隆。
    expect(c.length, 2);
    expect(c[0], same(r1));
    expect(c[1].name, '行1');
    expect(c[1], isNot(same(r1)));
  });

  testWidgets('批量粘贴：份数对话框一次贴 N 份', (tester) async {
    final c = UtenEditableGridController<_Row>(initial: [_Row('行1')]);
    await tester.pumpWidget(_wrap(_grid(c)));

    await tester.longPress(find.text('行1'));
    await tester.pump();
    await tester.tap(find.text('复制选中 (1)').last);
    await tester.pump();

    await tester.longPress(find.text('行1'));
    await tester.pump();
    await tester.tap(find.text('批量粘贴'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(c.length, 4); // 1 原行 + 3 份
  });

  testWidgets('在上方插入空行：新空行落在右键行的下标处', (tester) async {
    final c = UtenEditableGridController<_Row>(
      initial: [_Row('行1'), _Row('行2')],
    );
    await tester.pumpWidget(_wrap(_grid(c)));

    await tester.longPress(find.text('行2'));
    await tester.pump();
    await tester.tap(find.text('在上方插入空行'));
    await tester.pump();
    expect(c.length, 3);
    expect(c[1].name, '新行');
    expect(c[2].name, '行2');
  });

  testWidgets('删除选中：确认弹窗确认后才删', (tester) async {
    final c = UtenEditableGridController<_Row>(
      initial: [_Row('行1'), _Row('行2')],
    );
    await tester.pumpWidget(_wrap(_grid(c)));

    await tester.longPress(find.text('行1'));
    await tester.pump();
    await tester.tap(find.text('删除选中 (1)'));
    await tester.pumpAndSettle();
    // 确认弹窗（UtenDialog，confirmLabel=删除）；取消先试一次。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(c.length, 2);

    await tester.longPress(find.text('行2'));
    await tester.pump();
    await tester.tap(find.text('删除选中 (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(c.length, 1);
    expect(c[0].name, '行1');
  });

  testWidgets('cloneRow 未提供：菜单不显复制粘贴组，仅插入/删除', (tester) async {
    final c = UtenEditableGridController<_Row>(initial: [_Row('行1')]);
    await tester.pumpWidget(_wrap(_grid(c, withClone: false)));

    await tester.longPress(find.text('行1'));
    await tester.pump();
    expect(find.text('复制选中 (1)'), findsNothing);
    expect(find.text('粘贴'), findsNothing);
    expect(find.text('批量粘贴'), findsNothing);
    expect(find.text('在上方插入空行'), findsOneWidget);
    expect(find.text('删除选中 (1)'), findsOneWidget);
  });

  testWidgets('只选/任务模式（showAddRow=false）长按不弹菜单', (tester) async {
    final c = UtenEditableGridController<_Row>(initial: [_Row('行1')]);
    await tester.pumpWidget(
      _wrap(_grid(c, showAddRow: false, selectable: true)),
    );

    await tester.longPress(find.text('行1'));
    await tester.pump();
    expect(find.text('删除选中 (1)'), findsNothing);
  });
}
