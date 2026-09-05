import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';

class _Row extends EditableGridRow {}

Widget _app({
  List<String> labels = const ['列A', '列B', '列C'],
  Set<String> requiredKeys = const {},
  Map<String, String> headerInfo = const {},
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
          ),
        ],
      ),
    ),
  );
}

Finder _option(String key) =>
    find.byKey(ValueKey('editable-grid-column-option-$key'));

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
      find.descendant(of: _option('列B'), matching: find.byType(Checkbox)),
    );
    await tester.pump();
    expect(find.text('表头设置 2/3'), findsOneWidget);

    final dragHandle = find.descendant(
      of: _option('列C'),
      matching: find.byIcon(Icons.drag_handle_rounded),
    );
    // 列B 虽隐藏仍保留在设置清单中；跨过两项把列C 移到列A 前。
    await tester.drag(dragHandle, const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

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

    // 底部列表勾选禁用并标注「必填列，不可隐藏」。
    await tester.tap(find.text('表头设置 3/3'));
    await tester.pumpAndSettle();
    expect(find.text('必填列，不可隐藏'), findsOneWidget);
    await tester.tap(
      find.descendant(of: _option('列A'), matching: find.byType(Checkbox)),
    );
    await tester.pump();
    expect(find.text('表头设置 3/3'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
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
    final chooser = find.byKey(const ValueKey('editable-grid-column-chooser'));
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
