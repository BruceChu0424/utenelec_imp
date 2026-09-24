// 字号档的整体缩放不能放大鼠标滚轮的屏幕位移；覆盖真实表格和页面滚动宿主。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/responsive/display_zoom_pointer_binding.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

const _window = Size(1920, 1600);
const _wheelDistance = 96.0;
const _gateDistance = 50.0;

Widget _table({
  bool primary = false,
  ValueChanged<String>? onRowTap,
  ValueChanged<String>? onSelectionChanged,
}) => MasterDataTableView<String>(
  primary: primary,
  onRowTap: onRowTap,
  onSelectionChanged: onSelectionChanged,
  columns: [
    for (var column = 0; column < 16; column++)
      MasterColumnDef<String>(
        key: 'c$column',
        label: '列$column',
        width: 140,
        value: (value) => '$value/$column',
        cellBuilder: column == 0 ? (_, value) => Text(value) : null,
      ),
  ],
  items: [for (var row = 0; row < 120; row++) 'ROW-$row'],
  facets: const {},
  nullCounts: const {},
  filters: const {},
  onFilterChanged: (_, _) {},
);

Future<void> _pump(
  WidgetTester tester, {
  required double zoom,
  required Widget child,
}) async {
  tester.view.physicalSize = _window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.windows),
      scrollBehavior: const UtenScrollBehavior(),
      builder: (context, child) =>
          UtenDisplayZoomBox(fontFactor: zoom, child: child!),
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _wheel(
  WidgetTester tester, {
  Offset? at,
  double distance = _wheelDistance,
}) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(
    pointer.hover(at ?? tester.getCenter(find.text('ROW-5'))),
  );
  await tester.sendEventToBinding(pointer.scroll(Offset(0, distance)));
  await tester.pumpAndSettle();
}

ScrollPosition _tableVerticalPosition(WidgetTester tester) {
  final scrollables = find.descendant(
    of: find.byType(ListView),
    matching: find.byType(Scrollable),
  );
  return tester
      .stateList<ScrollableState>(scrollables)
      .singleWhere((state) => state.position.axis == Axis.vertical)
      .position;
}

class _GridRow extends EditableGridRow {
  _GridRow(this.label);

  final String label;
}

class _ZoomTableTestBinding extends AutomatedTestWidgetsFlutterBinding
    with UtenDisplayZoomPointerEvents {}

void main() {
  _ZoomTableTestBinding();
  for (final zoom in [1.0, 1.5, 2.0]) {
    testWidgets('独立表格 $zoom 倍字号：一格滚轮的屏幕位移保持一致', (tester) async {
      await _pump(tester, zoom: zoom, child: _table());
      final before = tester.getTopLeft(find.text('ROW-5')).dy;

      await _wheel(tester);

      expect(
        before - tester.getTopLeft(find.text('ROW-5')).dy,
        closeTo(_wheelDistance, 0.01),
      );
      expect(
        _tableVerticalPosition(tester).pixels,
        closeTo(_wheelDistance / zoom, 0.01),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('联动表格 $zoom 倍字号：交接门保留、表内滚动不随字号加速', (tester) async {
      final outer = ScrollController();
      addTearDown(outer.dispose);
      await _pump(
        tester,
        zoom: zoom,
        child: UtenCollapsingHeaderScrollView(
          controller: outer,
          collapsingHeader: const SizedBox(height: 120),
          body: _table(primary: true),
        ),
      );
      expect(find.byType(NestedScrollView), findsOneWidget);
      final inner = _tableVerticalPosition(tester);

      // 跨过交接点的一格只收头部；超出头部高度的余量不会带走第一行。
      await _wheel(tester, distance: 1000);
      expect(outer.offset, closeTo(outer.position.maxScrollExtent, 0.01));
      expect(inner.pixels, 0);
      // 交接门仍按画布距离计算，恰好吃完门不会提前滚入表体。
      await _wheel(tester, distance: _gateDistance * zoom);
      expect(inner.pixels, 0);
      final before = tester.getTopLeft(find.text('ROW-5')).dy;

      await _wheel(tester);

      expect(inner.pixels, closeTo(_wheelDistance / zoom, 0.01));
      expect(
        before - tester.getTopLeft(find.text('ROW-5')).dy,
        closeTo(_wheelDistance, 0.01),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('紧凑回退表格 $zoom 倍字号：原生内滚保持相同屏幕位移', (tester) async {
      final outer = ScrollController();
      addTearDown(outer.dispose);
      await _pump(
        tester,
        zoom: zoom,
        child: UtenCollapsingHeaderScrollView(
          controller: outer,
          compactBreakpoint: 3000,
          collapsingHeader: const SizedBox(height: 120),
          body: _table(primary: true),
        ),
      );
      expect(find.byType(NestedScrollView), findsNothing);
      outer.jumpTo(outer.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(find.text('ROW-5')).dy;
      final outerBefore = outer.offset;

      await _wheel(tester);

      expect(outer.offset, outerBefore);
      expect(
        _tableVerticalPosition(tester).pixels,
        closeTo(_wheelDistance / zoom, 0.01),
      );
      expect(
        before - tester.getTopLeft(find.text('ROW-5')).dy,
        closeTo(_wheelDistance, 0.01),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('编辑表格 $zoom 倍字号：页面外滚保持相同屏幕位移', (tester) async {
      final page = ScrollController();
      final grid = UtenEditableGridController<_GridRow>(
        initial: [for (var row = 0; row < 120; row++) _GridRow('GRID-$row')],
      );
      addTearDown(page.dispose);
      addTearDown(grid.dispose);
      await _pump(
        tester,
        zoom: zoom,
        child: ListView(
          controller: page,
          children: [
            UtenEditableGrid<_GridRow>(
              controller: grid,
              showAddRow: false,
              columns: [
                EditableGridColumn<_GridRow>(
                  key: 'value',
                  label: '内容',
                  width: 320,
                  cellBuilder: (_, row) => Text(row.label),
                ),
              ],
            ),
          ],
        ),
      );
      final row = find.text('GRID-5');
      final before = tester.getTopLeft(row).dy;

      await _wheel(tester, at: tester.getCenter(row));

      expect(page.offset, closeTo(_wheelDistance / zoom, 0.01));
      expect(before - tester.getTopLeft(row).dy, closeTo(_wheelDistance, 0.01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('表格 $zoom 倍字号：Shift 滚轮仍横滚且不加速', (tester) async {
      await _pump(tester, zoom: zoom, child: _table());
      final scrollableStates = tester.stateList<ScrollableState>(
        find.byType(Scrollable),
      );
      final horizontal = scrollableStates
          .where((state) => state.position.axis == Axis.horizontal)
          .map((state) => state.position)
          .toList();
      expect(horizontal, isNotEmpty);
      expect(
        horizontal.every((position) => position.maxScrollExtent > 0),
        isTrue,
      );
      final at = tester.getCenter(find.text('ROW-5'));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      try {
        await _wheel(tester, at: at);
      } finally {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      }

      expect(_tableVerticalPosition(tester).pixels, 0);
      for (final position in horizontal) {
        expect(position.pixels, closeTo(_wheelDistance / zoom, 0.01));
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final primary in [false, true]) {
    testWidgets('2 倍字号真实表格竖条可拖到边界，行操作不误触 primary=$primary', (tester) async {
      final outer = ScrollController();
      addTearDown(outer.dispose);
      var rowTaps = 0;
      var selections = 0;
      final table = _table(
        primary: primary,
        onRowTap: (_) => rowTaps++,
        onSelectionChanged: (_) => selections++,
      );
      await _pump(
        tester,
        zoom: 2,
        child: primary
            ? UtenCollapsingHeaderScrollView(
                controller: outer,
                collapsingHeader: const SizedBox(height: 120),
                body: table,
              )
            : table,
      );
      if (primary) await _wheel(tester, distance: 1000);
      final barFinder = find.byType(UtenContentScrollbar);
      expect(tester.widget<UtenContentScrollbar>(barFinder).visible, isTrue);
      final bar = tester.getRect(barFinder);
      final vertical = _tableVerticalPosition(tester);
      final horizontal = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .where((state) => state.position.axis == Axis.horizontal)
          .map((state) => state.position)
          .toList();
      // Thumb 当前在顶部；用窗口坐标点击缩放后的 thumb 中部。
      final start = Offset(bar.right - 12, bar.top + 40);
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(vertical.pixels, greaterThan(0));

      await gesture.moveTo(Offset(start.dx, bar.bottom + 200));
      await tester.pumpAndSettle();
      expect(vertical.pixels, closeTo(vertical.maxScrollExtent, 0.01));
      await gesture.moveTo(Offset(start.dx, bar.top - 200));
      await tester.pumpAndSettle();
      expect(vertical.pixels, closeTo(vertical.minScrollExtent, 0.01));
      await gesture.up();
      await tester.pumpAndSettle();

      if (primary) {
        expect(outer.offset, closeTo(outer.position.maxScrollExtent, 0.01));
      }
      expect(horizontal.every((position) => position.pixels == 0), isTrue);
      expect(rowTaps, 0);
      expect(selections, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('2 倍字号真实表格横条可按住拖动且表头同步', (tester) async {
    var selections = 0;
    await _pump(
      tester,
      zoom: 2,
      child: _table(onSelectionChanged: (_) => selections++),
    );
    final horizontalBar = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollbar &&
          widget.controller?.position.axis == Axis.horizontal,
    );
    expect(horizontalBar, findsOneWidget);
    final rect = tester.getRect(horizontalBar);
    final gesture = await tester.startGesture(
      Offset(rect.left + 80, rect.bottom - 6),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(160, 0));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    final horizontal = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .where((state) => state.position.axis == Axis.horizontal)
        .map((state) => state.position)
        .toList();
    expect(horizontal.every((position) => position.pixels > 0), isTrue);
    for (final position in horizontal) {
      expect(position.pixels, closeTo(horizontal.first.pixels, 0.01));
    }
    expect(_tableVerticalPosition(tester).pixels, 0);
    expect(selections, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('紧凑回退：滚轮先收头部把表格送顶，交接后才滚表内（大字号桌面口径）', (tester) async {
    // 2026-09-24 用户反馈「字体放大后表格不会滑到顶」：大字号把 1080p 桌面压进
    // 紧凑回退分支后，滚轮被表内 Scrollable 直接吃掉，头部永不收起。滚轮交接门
    // 已扩展到紧凑分支——本测试锁定「先页滚送顶→门→表内滚→反向先回表内」。
    final outer = ScrollController();
    addTearDown(outer.dispose);
    await _pump(
      tester,
      zoom: 1.5,
      child: UtenCollapsingHeaderScrollView(
        controller: outer,
        compactBreakpoint: 3000,
        collapsingHeader: const SizedBox(height: 300),
        body: _table(primary: true),
      ),
    );
    expect(find.byType(NestedScrollView), findsNothing);
    final inner = _tableVerticalPosition(tester);
    expect(outer.offset, 0);
    expect(inner.pixels, 0);

    // 上滚一格：整页先滚（收头部），表内不动。
    await _wheel(tester);
    expect(outer.offset, greaterThan(0));
    expect(inner.pixels, 0);

    // 一直滚到页顶：表格送到视口顶，恰好置顶的那格余量丢弃并上门。
    for (
      var i = 0;
      i < 30 && outer.offset < outer.position.maxScrollExtent - 0.5;
      i++
    ) {
      await _wheel(tester, distance: 500);
    }
    expect(outer.offset, closeTo(outer.position.maxScrollExtent, 0.01));
    expect(inner.pixels, 0);

    // 吃完交接门的空行程后，表内开始滚。
    await _wheel(tester, distance: _gateDistance * 1.5 + _wheelDistance);
    expect(inner.pixels, greaterThan(0));

    // 反向：先把表内滚回顶，头部才放出来。
    final pageTop = outer.offset;
    await _wheel(tester, distance: -(inner.pixels + _gateDistance * 2 + 200));
    expect(inner.pixels, closeTo(0, 0.01));
    expect(outer.offset, closeTo(pageTop, 0.01));
    await _wheel(tester, distance: -500);
    expect(outer.offset, lessThan(pageTop));
    expect(tester.takeException(), isNull);
  });
}
