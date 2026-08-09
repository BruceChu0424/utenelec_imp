import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_plan_wizard_page.dart';

void main() {
  testWidgets(
    'multi-paper wizard applies schedule, navigates and returns per-item fields',
    (tester) async {
      List<MaterialAnalysisPlanItemInput>? result;
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            departmentPickerTreeProvider.overrideWith(
              (ref) async => const <DepartmentNode>[],
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  onPressed: () async {
                    result = await Navigator.of(context)
                        .push<List<MaterialAnalysisPlanItemInput>>(
                          MaterialPageRoute(
                            builder: (_) =>
                                ProductionPlanWizardPage(entries: _entries()),
                          ),
                        );
                  },
                  child: const Text('打开计划单'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开计划单'));
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 2 张 · 一种自制件一个执行批次'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('production-plan-wizard-apply-remaining')),
      );
      ScaffoldMessenger.of(
        tester.element(find.byType(ProductionPlanWizardPage)),
      ).hideCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('production-plan-wizard-next')));
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 2 张 · 一种自制件一个执行批次'), findsOneWidget);

      await tester.tap(find.text('上一张'));
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 2 张 · 一种自制件一个执行批次'), findsOneWidget);
      await tester.tap(find.byKey(const Key('production-plan-wizard-next')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('汇总确认'));
      await tester.pumpAndSettle();
      expect(find.text('确认提交 2 张生产计划单'), findsOneWidget);
      await tester.tap(find.byKey(const Key('production-plan-wizard-submit')));
      await tester.pumpAndSettle();

      expect(result, hasLength(2));
      expect(result![0].toJson(), {
        'analysisLineId': 'product-1',
        'qty': 4.0,
        'billDate': '2026-08-10',
        'deliveryDate': '2026-08-12',
        'departmentId': 'workshop-1',
        'workshopName': '装配一车间',
        'workerId': 'worker-1',
        'teamDepartmentId': 'team-1',
      });
      expect(result![1].departmentId, 'workshop-1');
      expect(result![1].workshopName, '装配一车间');
      expect(result![1].workerId, 'worker-1');
      expect(result![1].billDate, '2026-08-10');
      expect(result![1].deliveryDate, '2026-08-12');
    },
  );

  testWidgets('compact wizard keeps one-paper form and actions usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          departmentPickerTreeProvider.overrideWith(
            (ref) async => const <DepartmentNode>[],
          ),
        ],
        child: MaterialApp(
          home: ProductionPlanWizardPage(entries: [_entries().first]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('第 1 / 1 张 · 一种自制件一个执行批次'), findsOneWidget);
    expect(find.text('汇总确认'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('production-plan-paper-product-1')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

List<ProductionPlanWizardEntry> _entries() => [
  ProductionPlanWizardEntry(
    product: _product('product-1', '成品 A', 6),
    qty: 4,
    billDate: DateTime(2026, 8, 10),
    deliveryDate: DateTime(2026, 8, 12),
    departmentId: 'workshop-1',
    workshopName: '装配一车间',
    workerId: 'worker-1',
    workerName: '张三',
    teamDepartmentId: 'team-1',
  ),
  ProductionPlanWizardEntry(
    product: _product('product-2', '自制件 B', 3, makeComponent: true),
    qty: 2,
    billDate: DateTime(2026, 8, 15),
    deliveryDate: DateTime(2026, 8, 18),
    departmentId: 'workshop-2',
    workshopName: '注塑车间',
    workerId: 'worker-2',
    workerName: '李四',
  ),
];

ProductionMaterialAnalysisProduct _product(
  String id,
  String name,
  double readyNow, {
  bool makeComponent = false,
}) => ProductionMaterialAnalysisProduct(
  analysisLineId: id,
  sourceType: makeComponent ? 'MAKE_COMPONENT' : 'SALES_ORDER',
  goodsCode: id.toUpperCase(),
  goodsName: name,
  readyNowQty: readyNow,
  readyFinishQty: readyNow,
  remainingQty: readyNow,
);
