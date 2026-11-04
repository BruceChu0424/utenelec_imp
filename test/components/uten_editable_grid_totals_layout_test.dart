import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';

class _Row extends EditableGridRow {}

Widget _app(
  UtenEditableGridController<_Row> controller, {
  required double width,
  double scale = 1,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(
          width: width,
          child: UtenEditableGrid<_Row>(
            controller: controller,
            columns: [
              EditableGridColumn<_Row>(
                key: 'value',
                label: '明细',
                width: 120,
                cellBuilder: (_, _) => const Text('测试行'),
              ),
            ],
            createBlankRow: _Row.new,
            footer: const UtenTotalsSummaryBar(
              compact: true,
              entries: [UtenTotalEntry('合计金额', '987654321.123456789')],
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('桌面添加行在左、汇总在同一行最右，连续添加保留全部行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = UtenEditableGridController<_Row>(initial: [_Row()]);
    await tester.pumpWidget(_app(controller, width: 1200));
    await tester.pumpAndSettle();
    final add = tester.getRect(find.text('添加行'));
    final total = tester.getRect(find.text('987654321.123456789'));
    expect((add.center.dy - total.center.dy).abs(), lessThan(10));
    expect(total.right, closeTo(1200, 1));
    expect(total.left, greaterThan(add.right));
    for (var i = 0; i < 15; i++) {
      await tester.ensureVisible(find.text('添加行'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加行'));
      await tester.pump();
    }
    expect(controller.rows, hasLength(16));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  for (final size in [(390.0, 1.0), (640.0, 2.0)]) {
    testWidgets('宽${size.$1} 字体${size.$2}时先显示添加行，再右对齐完整汇总', (tester) async {
      await tester.binding.setSurfaceSize(Size(size.$1, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = UtenEditableGridController<_Row>(initial: [_Row()]);
      await tester.pumpWidget(_app(controller, width: size.$1, scale: size.$2));
      await tester.pumpAndSettle();
      final add = tester.getRect(find.text('添加行'));
      final total = tester.getRect(find.text('987654321.123456789'));
      expect(total.top, greaterThan(add.bottom));
      expect(total.right, closeTo(size.$1, 1));
      expect(total.left, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }
}
