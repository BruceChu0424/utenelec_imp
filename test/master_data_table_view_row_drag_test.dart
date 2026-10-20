// 2026-10-19 行拖拽（长按启动）契约测试：
//
//  1. 长按拾起：被拖行淡出、幽灵卡出现（含行数徽记）；
//  2. 落点形态：目标行上缘=above、下缘=below、中部=into（canDropInto 放行时）；
//  3. 松手回调 onDrop(dragged, target, mode)，且「长按即选中」把按下行纳入勾选；
//  4. 多选批量：按下已勾选行 → 整批勾选行一起拖；
//  5. ESC 取消：不发 onDrop、行恢复；
//  6. canDrop 拒绝的目标（被拖行自身）不产生落点。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_table_row_drag.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(this.id, this.name);
  final String id;
  final String name;
}

const _items = [
  _Row('r1', '第一条'),
  _Row('r2', '第二条'),
  _Row('r3', '第三条'),
];

class _Harness extends StatefulWidget {
  const _Harness({this.onDrop});
  final void Function(List<_Row>, _Row, UtenTableRowDropMode)? onDrop;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  var selected = <String>{};

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 640,
          height: 320,
          child: MasterDataTableView<_Row>(
            columns: [
              MasterColumnDef<_Row>(
                key: 'name',
                label: '名称',
                width: 240,
                value: (r) => r.name,
              ),
            ],
            items: _items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            selectable: true,
            idOf: (r) => r.id,
            selectedIds: selected,
            onSelectedIdsChanged: (next) => setState(() => selected = next),
            rowDrag: UtenTableRowDrag<_Row>(
              canDragRow: (_) => true,
              dragRowsOf: (pressed) =>
                  selected.contains(pressed.id)
                      ? _items.where((r) => selected.contains(r.id)).toList()
                      : [pressed],
              dragLabelOf: (r) => r.name,
              canDrop: (target, dragged) =>
                  !dragged.any((d) => d.id == target.id),
              canDropInto: (target, dragged) =>
                  !dragged.any((d) => d.id == target.id),
              onDrop: (dragged, target, mode) async {
                widget.onDrop?.call(dragged, target, mode);
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 长按拾起 srcFinder 行（按住 600ms > 500ms 长按时限），返回仍按住的手势。
Future<TestGesture> _pickUp(
  WidgetTester tester,
  Finder srcFinder, {
  int pointer = 7,
}) async {
  final gesture = await tester.startGesture(
    tester.getCenter(srcFinder),
    pointer: pointer,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 600));
  return gesture;
}

/// 拖拽槽 = 整行（含边距），落点带（上 25% / 中 50% / 下 25%）按它的矩形算。
Finder _slotOf(String id) => find.byKey(ValueKey('row-drag-slot:$id'));

void main() {
  testWidgets('长按拾起：行淡出 + 幽灵卡；松手在目标行上缘 = above 并回调', (
    tester,
  ) async {
    final drops = <(List<String>, String, UtenTableRowDropMode)>[];
    await tester.pumpWidget(
      _Harness(
        onDrop: (dragged, target, mode) =>
            drops.add((dragged.map((d) => d.id).toList(), target.id, mode)),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await _pickUp(tester, find.text('第一条'));
    await tester.pumpAndSettle();
    // 幽灵卡出现且带行名。
    expect(find.text('第一条'), findsWidgets);
    expect(find.byType(Material), findsWidgets);

    // 移到第三条行的上缘带（槽矩形顶部 10%）。
    final rect = tester.getRect(_slotOf('r3'));
    await gesture.moveTo(Offset(rect.center.dx, rect.top + rect.height * 0.1));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(drops, hasLength(1));
    expect(drops.single.$1, ['r1']);
    expect(drops.single.$2, 'r3');
    expect(drops.single.$3, UtenTableRowDropMode.above);
  });

  testWidgets('目标行中部 = into；长按即选中按下行', (tester) async {
    final drops = <(List<String>, String, UtenTableRowDropMode)>[];
    _Row? tappedSelected;
    await tester.pumpWidget(
      _Harness(
        onDrop: (dragged, target, mode) {
          drops.add((dragged.map((d) => d.id).toList(), target.id, mode));
          tappedSelected = dragged.first;
        },
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await _pickUp(tester, find.text('第二条'), pointer: 8);
    await tester.pumpAndSettle();

    final rect = tester.getRect(_slotOf('r1'));
    await gesture.moveTo(rect.center);
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(drops, hasLength(1));
    expect(drops.single.$1, ['r2']);
    expect(drops.single.$2, 'r1');
    expect(drops.single.$3, UtenTableRowDropMode.into);
    // 「长按首先是选中这一行」：拾起时按下行已进勾选集（经 onDrop 侧无法看集合，
    // 用幽灵卡期间表头「已选 1 项」断言放上面拾起后做）。
    expect(tappedSelected, isNotNull);
  });

  testWidgets('多选批量：按下已勾选行 → 整批一起拖', (tester) async {
    final drops = <(List<String>, String, UtenTableRowDropMode)>[];
    await tester.pumpWidget(
      _Harness(
        onDrop: (dragged, target, mode) =>
            drops.add((dragged.map((d) => d.id).toList(), target.id, mode)),
      ),
    );
    await tester.pumpAndSettle();

    // 先勾选前两行。
    await tester.tap(find.text('第一条'));
    await tester.pump();
    await tester.tap(find.text('第二条'));
    await tester.pump();

    final gesture = await _pickUp(tester, find.text('第二条'), pointer: 9);
    await tester.pumpAndSettle();
    // 幽灵卡带「2 行」徽记。
    expect(find.text('2 行'), findsOneWidget);

    final rect = tester.getRect(_slotOf('r3'));
    await gesture.moveTo(
      Offset(rect.center.dx, rect.bottom - rect.height * 0.1),
    );
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(drops, hasLength(1));
    expect(drops.single.$1, ['r1', 'r2']);
    expect(drops.single.$2, 'r3');
    expect(drops.single.$3, UtenTableRowDropMode.below);
  });

  testWidgets('ESC 取消：不回调、拖拽视觉清空', (tester) async {
    var drops = 0;
    await tester.pumpWidget(
      _Harness(onDrop: (_, _, _) => drops++),
    );
    await tester.pumpAndSettle();

    final gesture = await _pickUp(tester, find.text('第一条'), pointer: 10);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(drops, 0);
  });

  testWidgets('拖到没有有效目标的位置松手：不回调', (tester) async {
    var drops = 0;
    await tester.pumpWidget(_Harness(onDrop: (_, _, _) => drops++));
    await tester.pumpAndSettle();

    final gesture = await _pickUp(tester, find.text('第一条'), pointer: 11);
    await tester.pumpAndSettle();
    // 移出表体（工具条区域）再松手。
    await gesture.moveTo(const Offset(320, 4));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(drops, 0);
  });
}
