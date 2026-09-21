// UtenDragReorderList（Draggable 版拖手柄换位列表）测试。
//
// 1) 按住手柄拖过其余项中点即换位：onReorder(old, new) 语义与
//    ReorderableListView.onReorderItem 一致（newIndex = 最终下标）；
// 2) 根部整体缩放（UtenDisplayZoomBox，2560 窗口 → zoom 4/3）之下，用窗口坐标拖动
//    仍换到正确位置，且拖影盖在原项上（不偏 zoom 倍——这正是弃用
//    ReorderableListView 的原因）；
// 3) 越出列表上沿：钳到首位；固定行由宿主钳位（组件不裁剪）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_drag_reorder_list.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';

/// 三项 60 高的列表夹具；宿主按 removeAt/insert 语义写回顺序。
class _Host extends StatefulWidget {
  const _Host({required this.onReorder, this.embedded = true});

  final void Function(int oldIndex, int newIndex)? onReorder;
  final bool embedded;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  List<String> order = ['a', 'b', 'c'];

  void _reorder(int oldIndex, int newIndex) {
    widget.onReorder?.call(oldIndex, newIndex);
    setState(() {
      final moved = order.removeAt(oldIndex);
      order.insert(newIndex, moved);
    });
  }

  Widget _item(BuildContext context, int index) {
    final id = order[index];
    return SizedBox(
      key: ValueKey('row-$id'),
      height: 60,
      child: Row(
        children: [
          Expanded(child: Text('项 $id')),
          UtenDragReorderHandle(
            index: index,
            immediate: true,
            child: SizedBox(
              key: ValueKey('handle-$id'),
              width: 40,
              height: 40,
              child: const Icon(Icons.drag_handle_rounded),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return SingleChildScrollView(
        child: UtenDragReorderList.embedded(
          ids: order,
          itemBuilder: _item,
          onReorder: _reorder,
        ),
      );
    }
    return UtenDragReorderList(
      ids: order,
      itemBuilder: _item,
      onReorder: _reorder,
    );
  }
}

Finder _handle(String id) => find.byKey(ValueKey('handle-$id'));
Finder _row(String id) => find.byKey(ValueKey('row-$id'));

void main() {
  testWidgets('按住手柄拖过其余项中点即换位（newIndex = 最终下标）', (tester) async {
    final calls = <(int, int)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _Host(onReorder: (o, n) => calls.add((o, n)))),
      ),
    );
    await tester.pumpAndSettle();

    // 项 a 手柄（中心 y=30）向下拖 130 → y=160，越过 b(90)、c(150) 中点 → 落到末位。
    await tester.drag(_handle('a'), const Offset(0, 130));
    await tester.pumpAndSettle();
    expect(calls, [(0, 2)]);
    expect(
      tester.getTopLeft(_row('b')).dy,
      lessThan(tester.getTopLeft(_row('a')).dy),
    );
    expect(
      tester.getTopLeft(_row('c')).dy,
      lessThan(tester.getTopLeft(_row('a')).dy),
    );

    // 再把 a 拖回顶（越出列表上沿：钳到首位）。
    await tester.drag(_handle('a'), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(calls.last, (2, 0));
    expect(
      tester.getTopLeft(_row('a')).dy,
      lessThan(tester.getTopLeft(_row('b')).dy),
    );
  });

  testWidgets('自带 ListView 承载：同样换位', (tester) async {
    final calls = <(int, int)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _Host(embedded: false, onReorder: (o, n) => calls.add((o, n))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 项 c（中心 y=150）向上拖 100 → y=50：越过 b(90) 中点、未过 a(30) → 落到下标 1。
    await tester.drag(_handle('c'), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(calls, [(2, 1)]);
  });

  testWidgets('根部整体缩放 4/3 之下：窗口坐标拖动换到正确位置，拖影盖在原项上', (tester) async {
    tester.view.physicalSize = const Size(2560, 1440);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <(int, int)>[];
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => UtenDisplayZoomBox(
          fontFactor: 1,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: _Host(onReorder: (o, n) => calls.add((o, n)))),
      ),
    );
    await tester.pumpAndSettle();
    // 画布 60 高的行在窗口里是 80 高：a 行 0-80、b 行 80-160、c 行 160-240。
    expect(tester.getSize(_row('a')).height, 60);
    expect(tester.getRect(_row('a')).height, closeTo(80, 1e-6));

    // 起拖后拖影里还有一份 handle-a 副本，手柄坐标先量好。
    final handleCenter = tester.getCenter(_handle('a'));
    final gesture = await tester.startGesture(handleCenter);
    await tester.pump();
    // 先越过触发阈值，再停在 b 行中点之下、c 行中点之上（窗口 y=150 ≈ 画布 112.5）。
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.moveTo(Offset(handleCenter.dx, 150));
    await tester.pump();
    // 拖影（Material 浮层里的 row-a 副本）顶边应贴着指针换算后的位置：
    // 拖影锚点 = 起拖时指针在项内的位置（画布 (x, 30)），指针窗口 y=150 → 画布 112.5，
    // 拖影顶边画布 82.5 → 窗口 110（若按 SDK 混用坐标会跑到 150-30=120 之外更远）。
    final feedbackRows = find.byKey(const ValueKey('row-a'));
    expect(feedbackRows, findsNWidgets(2));
    final tops =
        feedbackRows
            .evaluate()
            .map(
              (e) =>
                  (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy,
            )
            .toList()
          ..sort();
    expect(tops.last, closeTo(110, 1.0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, [(0, 1)]);
    expect(
      tester.getTopLeft(_row('b')).dy,
      lessThan(tester.getTopLeft(_row('a')).dy),
    );
    expect(
      tester.getTopLeft(_row('a')).dy,
      lessThan(tester.getTopLeft(_row('c')).dy),
    );
  });

  testWidgets('拖影副本里的手柄不再起拖（不在列表作用域内只显示外观）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: _Host(onReorder: null))),
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(_handle('a')));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    // 拖影里的手柄是纯外观，不包 Draggable。
    expect(find.byType(Draggable<Object>), findsNWidgets(3));
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
