import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';

void main() {
  String qtyText(double? value) => value?.toStringAsFixed(0) ?? '—';

  testWidgets(
    'completed MAKE child keeps all three quantities in read-only details',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        const material = ProductionMaterialAnalysisMaterial(
          materialLineId: 'make-parent-1',
          delegatedToRequestedQty: 20,
          actionable: false,
        );
        const child = ProductionMaterialAnalysisProduct(
          analysisLineId: 'make-child-1',
          sourceType: 'MAKE_COMPONENT',
          goodsCode: 'MAKE-A',
          goodsName: '自制组件 A',
          requestedQty: 20,
          planExecutionStatus: 'COMPLETED',
          planExecutionPlannedQty: 18,
          planExecutionInboundQty: 18,
          latestPlanId: 'plan-1',
          latestPlanNo: 'PP-001',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320,
                child: MaterialAnalysisMakeChildDetails(
                  material: material,
                  child: child,
                  qtyText: qtyText,
                  statusLabel: '已完工入库',
                  planAction: TextButton(
                    key: const Key('view-plan'),
                    onPressed: () {},
                    child: const Text('查看生产计划'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('关联自制子任务'), findsOneWidget);
        expect(find.text('自制组件 A(MAKE-A)'), findsOneWidget);
        expect(find.text('已下达自制 20'), findsOneWidget);
        expect(find.text('计划量 18'), findsOneWidget);
        expect(find.text('已完工入库 18'), findsOneWidget);
        expect(find.byKey(const Key('view-plan')), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(
          tester.getSemantics(
            find.byKey(
              const ValueKey('material-make-child-summary-make-parent-1'),
            ),
          ),
          matchesSemantics(
            label:
                '关联自制子任务；自制组件 A(MAKE-A)；状态 已完工入库；'
                '已下达自制 20；计划量 18；已完工入库 18',
            isReadOnly: true,
          ),
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'missing execution projection says pending and uses child demand',
    (tester) async {
      const material = ProductionMaterialAnalysisMaterial(
        materialLineId: 'subcontract-parent-1',
        actionable: false,
      );
      const child = ProductionMaterialAnalysisProduct(
        analysisLineId: 'subcontract-child-1',
        sourceType: 'SUBCONTRACT_MAKE',
        sourceRef: '委外前置自制任务 001',
        requestedQty: 12,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 240,
              child: MaterialAnalysisMakeChildDetails(
                material: material,
                child: child,
                qtyText: qtyText,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('关联委外前置自制任务'), findsOneWidget);
      expect(find.text('已下达自制 12'), findsOneWidget);
      expect(find.text('计划量 待回传'), findsOneWidget);
      expect(find.text('已完工入库 待回传'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
