import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/quality/presentation/procurement_inspection_guidance.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inspection_repository.dart';

void main() {
  testWidgets('验收汇总按单位UUID分别相加，来源箱不参与再次换算', (tester) async {
    const pieces = ProcurementInspectionItem(
      id: 'piece',
      unitId: 'box',
      unitRate: 24,
      baseUnitId: 'piece-unit',
      baseUnitName: '个',
      sourceUnitName: '箱',
    );
    const weight = ProcurementInspectionItem(
      id: 'weight',
      unitId: 'kg',
      unitRate: 1,
      baseUnitId: 'kg-unit',
      baseUnitName: '千克',
      sourceUnitName: '千克',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Text(
            inspectionQuantityTotalText(context, [
              (pieces, 48),
              (pieces, 24),
              (weight, 5),
            ]),
          ),
        ),
      ),
    );
    expect(find.textContaining('72 个'), findsOneWidget);
    expect(find.textContaining('5 千克'), findsOneWidget);
    expect(find.textContaining('77'), findsNothing);
    expect(find.textContaining('箱'), findsNothing);
  });

  testWidgets('历史行缺少验收单位时不把原单单位当成验收单位也不合计未知量', (tester) async {
    const legacy = ProcurementInspectionItem(
      id: 'legacy',
      unitId: 'box',
      unitRate: 24,
      sourceUnitName: '箱',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Text(
            '${inspectionQuantityUnit(context, legacy)}\n'
            '${inspectionQuantityTotalText(context, [(legacy, 48), (legacy, 24)])}',
          ),
        ),
      ),
    );
    expect(find.textContaining('2 行验收单位待核对'), findsOneWidget);
    expect(find.textContaining('72'), findsNothing);
    expect(find.textContaining('箱'), findsNothing);
  });
}
