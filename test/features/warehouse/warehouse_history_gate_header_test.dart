// WarehouseHistoryGate 的分类栏常驻 (2026-10-01 修「点委外成品退货/委外损耗后
// 分类栏消失」)：externalHeader 钉在时间行上方常驻。
// 2026-10-04 起时间门默认「全部」（用户口径：进历史段直接看全量列表），
// 列表随挂载即构建；切「时间段」后分类栏仍在。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_history_time_filter.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_history_gate.dart';

void main() {
  testWidgets('默认「全部」直接构建列表，externalHeader 全程常驻', (tester) async {
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

    // 默认「全部」：挂载即构建列表（无引导占位态），分类栏可见。
    expect(find.text('分类栏-委外成品退货'), findsOneWidget);
    expect(find.text('列表-已选'), findsOneWidget);

    // 切到具体时间段：列表仍在，分类栏不随选择消失。
    tester
        .widget<UtenHistoryTimeFilter>(find.byType(UtenHistoryTimeFilter))
        .onChanged(
          UtenHistoryTimeValue.range(
            DateTimeRange(
              start: DateTime.utc(2026, 8),
              end: DateTime.utc(2026, 8, 31),
            ),
          ),
        );
    await tester.pumpAndSettle();
    expect(find.text('分类栏-委外成品退货'), findsOneWidget);
    expect(find.text('列表-已选'), findsOneWidget);
  });
}
