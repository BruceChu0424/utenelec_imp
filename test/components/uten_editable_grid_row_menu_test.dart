// UtenEditableGrid 行级右键/长按操作菜单的行为测试（2026-09-03 接入）：
// - 可编辑模式长按/右击未勾选行 → 先把选中集替换为仅该行再弹菜单（文件管理器语义）；
//   已勾选多行时长按其中一行 → 保留多选，菜单作用于整组；
// - 菜单条目与操作条同一套 controller 逻辑：复制选中/粘贴（追加表尾）/
//   批量粘贴（份数对话框）/在上方插入空行/删除选中（确认弹窗）；
// - 缓冲为空时粘贴置灰；cloneRow 未提供时不显复制粘贴组；
// - 只选/任务模式默认不挂菜单；显式 onRemoveRows 时才提供安全移出菜单/操作条。
// - 选择可用菜单动作后，等待该动作(含确认弹窗)完成再清空选中；仅点外部取消菜单保留选择。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';

class _Row extends EditableGridRow {
  _Row(this.name);

  final String name;
  bool selected = false;

  @override
  void dispose() {}
}

UtenEditableGrid<_Row> _grid(
  UtenEditableGridController<_Row> c, {
  bool showAddRow = true,
  bool selectable = false,
  bool withClone = true,
  void Function(List<_Row>)? onRemoveRows,
  bool controlledSelection = false,
  bool selectionEnabled = true,
  bool Function(_Row row)? canSelectRow,
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
    selectionEnabled: selectionEnabled,
    canSelectRow: canSelectRow,
    selectedOf: controlledSelection ? (row) => row.selected : null,
    onRowSelect: controlledSelection
        ? (row, next) => row.selected = next
        : null,
    onRemoveRows: onRemoveRows,
    removeRowsActionLabel: onRemoveRows == null ? '删除选中' : '移出本次登记',
    removeRowsDialogTitle: onRemoveRows == null ? '批量删除' : '移出本次登记',
    removeRowsConfirmLabel: onRemoveRows == null ? '删除' : '确认移出',
    removeRowsMessageBuilder: onRemoveRows == null
        ? null
        : (count) => '移出 $count 行但不删除来源',
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
    expect(c.isSelected(r2), isTrue);

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
    expect(c.selectedCount, 0);

    await tester.longPress(find.text('行1'));
    await tester.pump();
    await tester.tap(find.text('粘贴').last);
    await tester.pump();
    // 粘贴统一追加表尾：两行，末行是新克隆。
    expect(c.length, 2);
    expect(c[0], same(r1));
    expect(c[1].name, '行1');
    expect(c[1], isNot(same(r1)));
    expect(c.selectedCount, 0);
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
    expect(c.selectedCount, 1);
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(c.length, 4); // 1 原行 + 3 份
    expect(c.selectedCount, 0);
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
    expect(c.selectedCount, 0);
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
    expect(c.selectedCount, 0);
    expect(find.text('删除选中 (1)'), findsNothing);

    await tester.longPress(find.text('行2'));
    await tester.pump();
    expect(c.selectedCount, 1);
    expect(find.text('删除选中 (1)'), findsOneWidget);
    expect(find.text('删除选中 (1)').hitTestable(), findsOneWidget);
    await tester.tap(find.text('删除选中 (1)').hitTestable());
    await tester.pump();
    await tester.pump();
    expect(c.selectedCount, 1);
    expect(find.text('删除选中 (1)'), findsNothing);
    expect(find.text('批量删除'), findsOneWidget);
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

  testWidgets('只选模式点行身切换选中（与主数据表单击选中统一）', (tester) async {
    // 2026-09-05 物料分析车间计划表反馈：不能只点最前面的复选框——行身
    // （非输入区）点击同样切换选中；编辑模式不启用（点格输入优先）。
    final r1 = _Row('行1');
    final blocked = _Row('已登记');
    final pending = _Row('待登记');
    final c = UtenEditableGridController<_Row>(initial: [r1, blocked, pending]);
    await tester.pumpWidget(
      _wrap(
        _grid(
          c,
          showAddRow: false,
          selectable: true,
          canSelectRow: (row) => row.name != '已登记',
        ),
      ),
    );

    await tester.tap(find.text('行1'));
    await tester.pump();
    expect(c.isSelected(r1), isTrue);
    await tester.tap(find.text('行1'));
    await tester.pump();
    expect(c.isSelected(r1), isFalse);

    // 行级门控（canSelectRow=false）行身点选无效。
    await tester.tap(find.text('已登记'));
    await tester.pump();
    expect(c.isSelected(blocked), isFalse);
    await tester.tap(find.text('待登记'));
    await tester.pump();
    expect(c.isSelected(pending), isTrue);

    // 编辑模式（showAddRow=true）不启用行身点选。
    final e = UtenEditableGridController<_Row>(initial: [_Row('编辑行')]);
    await tester.pumpWidget(_wrap(_grid(e)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑行'));
    await tester.pump();
    expect(e.selectedCount, 0);
  });

  testWidgets('编辑模式操作条不再常驻全选/复制/批量删除（与货品资料统一）', (tester) async {
    // 2026-09-05：编辑模式（showAddRow）操作条只保留「表头设置」与宿主批量动作；
    // 全选走表头复选框、复制/粘贴/删除走行级右键/长按菜单。勾选后操作条也不得
    // 冒出「取消全选/复制选中/批量删除」常驻按钮。
    final c = UtenEditableGridController<_Row>(
      initial: [_Row('行1'), _Row('行2')],
    );
    await tester.pumpWidget(_wrap(_grid(c)));
    await tester.pumpAndSettle();

    expect(find.text('全选'), findsNothing);
    expect(find.text('取消全选'), findsNothing);
    expect(find.textContaining('复制选中 ('), findsNothing);
    expect(find.textContaining('批量删除 ('), findsNothing);
    expect(find.text('粘贴'), findsNothing);

    // 选中两行后依旧不显；全选入口 = 表头复选框（勾选列仍在）。
    c.selectAll();
    await tester.pump();
    expect(find.text('取消全选'), findsNothing);
    expect(find.textContaining('复制选中 ('), findsNothing);
    expect(find.byType(Checkbox), findsWidgets);

    // 功能仍可达：长按行出菜单，复制/删除走菜单。
    await tester.longPress(find.text('行1'));
    await tester.pump();
    expect(find.text('复制选中 (2)'), findsOneWidget);
    expect(find.text('删除选中 (2)'), findsOneWidget);
  });

  testWidgets('任务模式显式移出：复选批量与右键单行共用确认，完成后清空选择', (tester) async {
    final r1 = _Row('待登记1');
    final r2 = _Row('待登记2');
    final c = UtenEditableGridController<_Row>(initial: [r1, r2]);
    await tester.pumpWidget(
      _wrap(
        _grid(
          c,
          showAddRow: false,
          selectable: true,
          onRemoveRows: c.removeRows,
        ),
      ),
    );

    expect(find.text('移出本次登记 (0)'), findsOneWidget);
    await _rightClick(tester, find.text('待登记2'));
    expect(find.text('移出本次登记 (1)').last, findsOneWidget);
    await tester.tap(find.text('移出本次登记 (1)').last);
    await tester.pumpAndSettle();
    expect(find.text('移出 1 行但不删除来源'), findsOneWidget);
    await tester.tap(find.text('确认移出'));
    await tester.pumpAndSettle();

    expect(c.rows.map((row) => row.name), ['待登记1']);
    expect(c.selectedCount, 0);
  });

  testWidgets('任务模式勾选多行可从操作条一次移出', (tester) async {
    final r1 = _Row('待登记1');
    final r2 = _Row('待登记2');
    final c = UtenEditableGridController<_Row>(initial: [r1, r2]);
    await tester.pumpWidget(
      _wrap(
        _grid(
          c,
          showAddRow: false,
          selectable: true,
          onRemoveRows: c.removeRows,
        ),
      ),
    );

    c.selectAll();
    await tester.pump();
    await tester.tap(find.text('移出本次登记 (2)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认移出'));
    await tester.pumpAndSettle();

    expect(c.rows, isEmpty);
    expect(c.selectedCount, 0);
  });

  testWidgets('任务移出会清掉已离开 controller 的外部受控选择快照', (tester) async {
    final row = _Row('受控待登记');
    final c = UtenEditableGridController<_Row>(initial: [row]);
    await tester.pumpWidget(
      _wrap(
        _grid(
          c,
          showAddRow: false,
          selectable: true,
          controlledSelection: true,
          onRemoveRows: c.removeRows,
        ),
      ),
    );

    await _rightClick(tester, find.text('受控待登记'));
    expect(row.selected, isTrue);
    await tester.tap(find.text('移出本次登记 (1)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认移出'));
    await tester.pumpAndSettle();

    expect(c.rows, isEmpty);
    expect(row.selected, isFalse);
  });

  testWidgets('任务右键与复选共用 canSelectRow 门控', (tester) async {
    final blocked = _Row('已登记');
    final pending = _Row('待登记');
    final c = UtenEditableGridController<_Row>(initial: [blocked, pending]);
    await tester.pumpWidget(
      _wrap(
        _grid(
          c,
          showAddRow: false,
          selectable: true,
          onRemoveRows: c.removeRows,
          canSelectRow: (row) => identical(row, pending),
        ),
      ),
    );

    await _rightClick(tester, find.text('已登记'));
    expect(c.selectedCount, 0);
    expect(find.text('移出本次登记 (1)'), findsNothing);

    await _rightClick(tester, find.text('待登记'));
    expect(c.isSelected(pending), isTrue);
    expect(find.text('移出本次登记 (1)').last, findsOneWidget);
  });

  testWidgets('selectionEnabled=false 保留布局但禁用复选批量动作和右键菜单', (tester) async {
    final row = _Row('保存中的明细');
    final c = UtenEditableGridController<_Row>(initial: [row])..selectAll();
    await tester.pumpWidget(
      _wrap(
        _grid(
          c,
          showAddRow: false,
          selectable: true,
          onRemoveRows: c.removeRows,
          selectionEnabled: false,
        ),
      ),
    );

    final checkboxes = tester.widgetList<Checkbox>(find.byType(Checkbox));
    expect(checkboxes, isNotEmpty);
    expect(checkboxes.every((checkbox) => checkbox.onChanged == null), isTrue);
    final removeButton = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('移出本次登记 (1)'),
        matching: find.byType(TextButton),
      ),
    );
    expect(removeButton.onPressed, isNull);

    await _rightClick(tester, find.text('保存中的明细'));
    expect(find.text('移出本次登记 (1)'), findsOneWidget);
    expect(find.text('确认移出'), findsNothing);
  });
}
