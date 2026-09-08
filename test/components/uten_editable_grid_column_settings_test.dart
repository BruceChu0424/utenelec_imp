import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';

class _Row extends EditableGridRow {}

Widget _app({
  List<String> labels = const ['列A', '列B', '列C'],
  Set<String> requiredKeys = const {},
  Map<String, String> headerInfo = const {},
  void Function(List<String> order, Set<String> hidden)? onChanged,
}) {
  final controller = UtenEditableGridController<_Row>(initial: [_Row()]);
  return MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          UtenEditableGrid<_Row>(
            controller: controller,
            columns: [
              for (final label in labels)
                EditableGridColumn<_Row>(
                  key: label,
                  label: label,
                  width: 120,
                  required: requiredKeys.contains(label),
                  headerInfo: headerInfo[label],
                  cellBuilder: (_, _) => Text(label.toLowerCase()),
                ),
            ],
            showAddRow: false,
            showRowDelete: false,
            showColumnSettings: true,
            onColumnSettingsChanged: onChanged,
          ),
        ],
      ),
    ),
  );
}

Finder _option(String key) => find.byKey(ValueKey('uten-column-option-$key'));

/// 点弹层外空白关闭（锚定浮层与货品资料同款：无关闭钮，点外部即关）。
Future<void> _closeChooser(WidgetTester tester) async {
  await tester.tapAt(const Offset(10, 10));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('column chooser hides and reorders editable-grid columns', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('表头设置 3/3'), findsOneWidget);
    expect(find.text('全选'), findsNothing);
    await tester.tap(find.text('表头设置 3/3'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: _option('列B'), matching: find.byType(InkWell)),
    );
    await tester.pumpAndSettle();
    expect(find.text('表头设置 2/3'), findsOneWidget);

    final dragHandle = find.descendant(
      of: _option('列C'),
      matching: find.byIcon(Icons.drag_handle_rounded),
    );
    // 列B 虽隐藏仍保留在设置清单中；跨过两项把列C 移到列A 前。
    await tester.drag(dragHandle, const Offset(0, -240));
    await tester.pumpAndSettle();
    await _closeChooser(tester);

    expect(find.text('列B'), findsNothing);
    expect(
      tester.getTopLeft(find.text('列C')).dx,
      lessThan(tester.getTopLeft(find.text('列A')).dx),
    );
    expect(
      tester.getTopLeft(find.text('列c')).dx,
      lessThan(tester.getTopLeft(find.text('列a')).dx),
    );
  });

  testWidgets('vertical header drag hides a column but keeps one visible', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.drag(find.text('列A'), const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(find.text('表头设置 2/3'), findsOneWidget);
    expect(find.text('列A'), findsNothing);

    await tester.drag(find.text('列B'), const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(find.text('表头设置 1/3'), findsOneWidget);

    await tester.drag(find.text('列C'), const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(find.text('表头设置 1/3'), findsOneWidget);
    expect(find.text('列C'), findsOneWidget);
  });

  testWidgets(
    'vertical drag shows the topmost ghost (unified with master table)',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      final center = tester.getCenter(find.text('列A'));
      final gesture = await tester.startGesture(center);
      // 页面 ListView 与表头竖向手势竞争竞技场：分多步拖动（真机即连续 move），
      // 竞技场解决后 update 连续派发，累计 dy 过阈值 → armed。
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();

      // 原格（变淡留原位）+ root Overlay 跟手浮层各渲染一份文案 → 共 2。
      // 与货品资料同一份 UtenColumnDragHideHost 实现——浮层是独立 overlay 单元。
      expect(find.text('列A'), findsNWidgets(2));
      // 浮层明显位于原格下方（跟手位移，clamp 到 120）。
      final t0 = tester.getTopLeft(find.text('列A').at(0)).dy;
      final t1 = tester.getTopLeft(find.text('列A').at(1)).dy;
      expect((t1 - t0).abs(), greaterThan(80));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('表头设置 2/3'), findsOneWidget);
      expect(find.text('列A'), findsNothing);
    },
  );

  testWidgets(
    'long-press header drag reorders columns directly (unified with master)',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final changes = <(List<String>, Set<String>)>[];
      await tester.pumpWidget(_app(onChanged: (o, h) => changes.add((o, h))));
      await tester.pumpAndSettle();

      // 长按列A 拎起（~500ms）→ 横拖过列B（120 宽）→ 松手落位到列B 之后。
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('列A')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(const Offset(140, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // 表头与表体同步换序：列B → 列A → 列C。
      expect(
        tester.getTopLeft(find.text('列B')).dx,
        lessThan(tester.getTopLeft(find.text('列A')).dx),
      );
      expect(
        tester.getTopLeft(find.text('列b')).dx,
        lessThan(tester.getTopLeft(find.text('列a')).dx),
      );
      // 持久化回调收到新序（与表头设置弹窗拖拽同一出口）。
      expect(changes, isNotEmpty);
      expect(changes.last.$1.first, '列B');
    },
  );

  testWidgets('required column stays visible (chooser locked + drag no-op)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(_app(requiredKeys: {'列A'}));
    await tester.pumpAndSettle();

    // 表头纵向拖出隐藏对必填列无效（必填表头带红 * 后缀，用包含匹配）。
    await tester.drag(find.textContaining('列A'), const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(find.text('表头设置 3/3'), findsOneWidget);
    expect(find.textContaining('列A'), findsOneWidget);

    // 弹层勾选禁用并标注「必填列，不可隐藏」。
    await tester.tap(find.text('表头设置 3/3'));
    await tester.pumpAndSettle();
    expect(find.text('必填列，不可隐藏'), findsOneWidget);
    await tester.tap(
      find.descendant(of: _option('列A'), matching: find.byType(InkWell)),
    );
    await tester.pumpAndSettle();
    expect(find.text('表头设置 3/3'), findsOneWidget);
    await _closeChooser(tester);
    expect(find.textContaining('列A'), findsOneWidget);
  });

  testWidgets('headerInfo renders info icon with explanation tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(_app(headerInfo: {'列B': '1 = 保持原价；0.9 = 9折'}));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.byTooltip('1 = 保持原价；0.9 = 9折'), findsOneWidget);
  });

  testWidgets('375px column chooser remains usable with many columns', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final labels = List.generate(12, (index) => '字段${index + 1}');
    await tester.pumpWidget(_app(labels: labels));
    await tester.pumpAndSettle();

    await tester.tap(find.text('表头设置 12/12'));
    await tester.pumpAndSettle();
    final chooser = find.byKey(const ValueKey('uten-column-chooser-scroll'));
    final scrollable = find.descendant(
      of: chooser,
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      _option('字段12'),
      180,
      scrollable: scrollable,
    );
    expect(_option('字段12'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
