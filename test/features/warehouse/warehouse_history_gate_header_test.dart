// WarehouseHistoryGate 的分类栏常驻 (2026-10-01 修「点委外成品退货/委外损耗后
// 分类栏消失」)：externalHeader 钉在时间行上方，未选时间段（引导占位态）也可见，
// 选了「全部」后仍在。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_history_gate.dart';

void main() {
  testWidgets('externalHeader 在未选时间段与选完「全部」后都常驻', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WarehouseHistoryGate(
            externalHeader: const Text('分类栏-委外成品退货'),
            builder: (time) => Text(time.isNone ? '列表-未选' : '列表-已选'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 未选时间段（占位态）：分类栏可见，列表未构建。
    expect(find.text('分类栏-委外成品退货'), findsOneWidget);
    expect(find.textContaining('列表-'), findsNothing);

    // 选「全部」：列表构建后分类栏仍在（不随选择消失）。
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.text('分类栏-委外成品退货'), findsOneWidget);
    expect(find.text('列表-已选'), findsOneWidget);
  });
}
