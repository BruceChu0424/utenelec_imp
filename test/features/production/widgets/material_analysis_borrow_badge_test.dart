import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';

void main() {
  Future<void> pumpBadge(
    WidgetTester tester, {
    required IconData icon,
    required String label,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 207.5,
              child: Semantics(
                label: label,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: MediaQuery.withClampedTextScaling(
                    minScaleFactor: textScale,
                    maxScaleFactor: textScale,
                    child: MaterialAnalysisBorrowBadgeContent(
                      icon: icon,
                      label: label,
                      color: Colors.teal,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('borrow badge fits a 207.5px table column', (tester) async {
    const label = '已调入 123456.789 件 · 来自名称很长的跨部门生产计划产品与批次';

    await pumpBadge(tester, icon: Icons.call_received_rounded, label: label);

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.call_received_rounded), findsOneWidget);
    expect(find.bySemanticsLabel(label), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.textSpan?.toPlainText().contains(label) == true,
      ),
      findsOneWidget,
    );
  });

  testWidgets('cross-plan badge also fits with enlarged text', (tester) async {
    const label = '已让料 999999.9999 件 · 给超长名称接受计划 · 优先待补 888888.8888 件';

    await pumpBadge(
      tester,
      icon: Icons.outbox_outlined,
      label: label,
      textScale: 1.3,
    );

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.outbox_outlined), findsOneWidget);
    expect(find.bySemanticsLabel(label), findsOneWidget);
  });
}
