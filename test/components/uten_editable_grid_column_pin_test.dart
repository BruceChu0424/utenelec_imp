// UtenEditableGrid 表头右键菜单「固定到左侧」集成测试（2026-09-25）。
//
// 编辑表与主数据表的关键差异：单元控件绑定行级 TextEditingController /
// ValueNotifier，同一份 cellBuilder 不能挂载两次——横滚时钉在视口左缘的固定列
// 副本只能渲染只读文本快照（textOf → frozenTextOf → filterValueOf）。
// 这里锁定：快照渲染、持久化回调、无快照源的列固定入口置灰、未开启表头设置的
// 页面不出菜单。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';

class _Row extends EditableGridRow {
  _Row(this.name, String qty) : qty = TextEditingController(text: qty);
  final String name;
  final TextEditingController qty;
}

Widget _app({
  bool showColumnSettings = true,
  void Function(List<String> order, Set<String> hidden, Set<String> pinned)?
  onChanged,
  Set<String>? initialPinned,
}) {
  final rows = [_Row('甲', '10'), _Row('乙', '20')];
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 700,
        height: 400,
        child: ListView(
          children: [
            UtenEditableGrid<_Row>(
              controller: UtenEditableGridController<_Row>(initial: rows),
              columns: [
                EditableGridColumn<_Row>(
                  key: 'name',
                  label: '名称',
                  width: 150,
                  textOf: (r) => r.name,
                  cellBuilder: (_, r) => Text(r.name),
                ),
                // 数量列：无 textOf、有 frozenTextOf（输入列的快照源）。
                EditableGridColumn<_Row>(
                  key: 'qty',
                  label: '数量',
                  width: 150,
                  numeric: true,
                  frozenTextOf: (r) => r.qty.text,
                  cellBuilder: (_, r) => TextField(controller: r.qty),
                ),
                // 备注列：三级快照源全无 → 固定入口应置灰。
                EditableGridColumn<_Row>(
                  key: 'plain',
                  label: '无快照列',
                  width: 150,
                  cellBuilder: (_, r) => const Text('—'),
                ),
                for (var i = 0; i < 4; i++)
                  EditableGridColumn<_Row>(
                    key: 'x$i',
                    label: '补列$i',
                    width: 150,
                    textOf: (r) => 'x$i-${r.name}',
                    cellBuilder: (_, r) => Text('x$i-${r.name}'),
                  ),
              ],
              showAddRow: false,
              showRowDelete: false,
              showColumnSettings: showColumnSettings,
              initialPinnedColumnKeys: initialPinned,
              onColumnSettingsChanged: onChanged,
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pump();
}

Iterable<double> _visibleDxOf(Finder f) => f.hitTestable().evaluate().map(
  (e) => (e.renderObject as RenderBox).localToGlobal(Offset.zero).dx,
);

double _dxOf(Finder f) => (f.evaluate().first.renderObject as RenderBox)
    .localToGlobal(Offset.zero)
    .dx;

void main() {
  testWidgets('右击表头弹菜单；固定列搬至行首并随持久化回调上报', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final changes = <(List<String>, Set<String>, Set<String>)>[];
    await tester.pumpWidget(
      _app(onChanged: (o, h, p) => changes.add((o, h, p))),
    );
    await tester.pumpAndSettle();

    await _rightClick(tester, find.text('数量'));
    await tester.tap(find.text('固定到左侧'));
    await tester.pumpAndSettle();

    // 数量列成为第一数据列；回调上报固定集。
    expect(_dxOf(find.text('数量')), lessThan(_dxOf(find.text('名称'))));
    expect(changes, isNotEmpty);
    expect(changes.last.$3, {'qty'});
    expect(changes.last.$1.first, 'qty');

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  testWidgets('横滚后固定列以只读文本快照钉在视口左缘（非可编辑控件）', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(initialPinned: const {'qty'}));
    await tester.pumpAndSettle();

    // 初始（未滚动）：数量列是可编辑 TextField（原件，非快照）。
    expect(find.byType(TextField), findsWidgets);

    await tester.drag(find.text('x1-甲'), const Offset(-500, 0));
    await tester.pumpAndSettle();

    // 快照文本钉在左缘（选择列 44 + 数量列 150 = 194 之内）；被滚走的普通列出视口。
    expect(
      _visibleDxOf(find.text('10')).any((d) => d >= 0 && d < 194),
      isTrue,
      reason: '固定输入列的快照文本必须钉在视口左缘',
    );
    expect(_dxOf(find.text('名称')), lessThan(0));
  });

  testWidgets('三级快照源全无的列：固定入口置灰', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _rightClick(tester, find.text('无快照列'));
    final ink = find.ancestor(
      of: find.text('固定到左侧'),
      matching: find.byType(InkWell),
    );
    expect(
      (ink.evaluate().single.widget as InkWell).onTap,
      isNull,
      reason: '无 textOf/frozenTextOf/filterValueOf 的列不支持固定',
    );
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  testWidgets('未开启表头设置的页面：右击表头不弹菜单', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(showColumnSettings: false));
    await tester.pumpAndSettle();

    await _rightClick(tester, find.text('数量'));
    expect(find.text('固定到左侧'), findsNothing);
    expect(find.text('隐藏此列'), findsNothing);
  });

  testWidgets('取消固定经菜单操作并上报空固定集（跨会话回默认序原位）', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final changes = <(List<String>, Set<String>, Set<String>)>[];
    await tester.pumpWidget(
      _app(
        initialPinned: const {'qty'},
        onChanged: (o, h, p) {
          changes.add((o, h, p));
        },
      ),
    );
    await tester.pumpAndSettle();

    await _rightClick(tester, find.text('数量'));
    await tester.tap(find.text('取消固定'));
    await tester.pumpAndSettle();

    expect(changes, isNotEmpty);
    expect(changes.last.$3, isEmpty);
    // 跨会话重放的固定没有 origin 记录 → 按默认列序插回：qty 回到 name 之后
    //（默认序 name,qty,plain,...）。
    expect(changes.last.$1.indexOf('qty'), 1);
  });

  testWidgets('会话内固定再取消 = 精确回到固定前的位置', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final changes = <(List<String>, Set<String>, Set<String>)>[];
    await tester.pumpWidget(
      _app(onChanged: (o, h, p) => changes.add((o, h, p))),
    );
    await tester.pumpAndSettle();

    await _rightClick(tester, find.text('数量'));
    await tester.tap(find.text('固定到左侧'));
    await tester.pumpAndSettle();
    await _rightClick(tester, find.text('数量'));
    await tester.tap(find.text('取消固定'));
    await tester.pumpAndSettle();

    // 默认序原样恢复：name,qty,plain,x0..x3。
    expect(changes.last.$1.first, 'name');
    expect(changes.last.$1.indexOf('qty'), 1);
    expect(find.byIcon(Icons.push_pin_rounded), findsNothing);
  });
}
