import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_plan_wizard_page.dart';
import 'package:uten_imp/features/production/providers/production_department_provider.dart';

void main() {
  testWidgets(
    'multi-paper wizard copies only chosen fields and returns per-item assignments',
    (tester) async {
      List<MaterialAnalysisPlanItemInput>? result;
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionWorkshopTreeProvider.overrideWith(
              (ref) async => _workshops(),
            ),
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
      expect(find.text('第 1 / 2 张 · 一种自制件一个执行批次 · 单号审核后由系统生成'), findsOneWidget);
      expect(find.byType(ReorderableListView), findsOneWidget);
      expect(find.byTooltip('拖动调整本次提交顺序'), findsNWidgets(2));
      final productNoField = find.byKey(
        const Key('production-plan-wizard-product-no-product-1'),
      );
      expect(
        tester.widget<TextFormField>(productNoField).controller?.text,
        'V6-0001',
      );
      await tester.enterText(productNoField, 'V6-0099');

      await tester.tap(
        find.byKey(const Key('production-plan-wizard-apply-remaining')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('production-plan-bulk-copy-dates')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('production-plan-bulk-copy-assignment')),
            )
            .value,
        isFalse,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('production-plan-bulk-only-blank')),
            )
            .value,
        isTrue,
      );
      // Override existing dates so the copy effect is observable. The
      // assignment checkbox remains off, so workshop/owner stay per product.
      await tester.tap(
        find.byKey(const Key('production-plan-bulk-only-blank')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('production-plan-bulk-apply-confirm')),
      );
      await tester.pumpAndSettle();
      ScaffoldMessenger.of(
        tester.element(find.byType(ProductionPlanWizardPage)),
      ).hideCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('production-plan-wizard-next')));
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 2 张 · 一种自制件一个执行批次 · 单号审核后由系统生成'), findsOneWidget);

      await tester.tap(find.text('上一张'));
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 2 张 · 一种自制件一个执行批次 · 单号审核后由系统生成'), findsOneWidget);
      await tester.tap(find.byKey(const Key('production-plan-wizard-next')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('汇总确认'));
      await tester.pumpAndSettle();
      expect(find.text('确认提交 2 张生产计划单 · 2 个车间组'), findsOneWidget);
      expect(find.text('装配一车间 · 1 张'), findsOneWidget);
      expect(find.text('注塑车间 · 1 张'), findsOneWidget);
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
        'productNo': 'V6-0099',
      });
      expect(result![1].departmentId, 'workshop-2');
      expect(result![1].workshopName, '注塑车间');
      expect(result![1].workerId, 'worker-2');
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
          productionWorkshopTreeProvider.overrideWith(
            (ref) async => _workshops(),
          ),
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

    expect(find.text('第 1 / 1 张 · 一种自制件一个执行批次 · 单号审核后由系统生成'), findsOneWidget);
    expect(find.text('汇总确认'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('production-plan-paper-product-1')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'wizard shows company header and missing-workshop banner when no workshop prefilled',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionWorkshopTreeProvider.overrideWith(
              (ref) async => _workshops(),
            ),
            departmentPickerTreeProvider.overrideWith(
              (ref) async => const <DepartmentNode>[],
            ),
          ],
          child: MaterialApp(
            home: ProductionPlanWizardPage(
              entries: [
                ProductionPlanWizardEntry(
                  product: _product('product-9', '缺车间组件', 5),
                  qty: 5,
                  billDate: DateTime(2026, 8, 11),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('中山市优腾电器有限公司'), findsOneWidget);
      expect(
        find.byKey(const Key('production-plan-wizard-missing-workshop')),
        findsOneWidget,
      );
      expect(find.textContaining('还没有默认生产车间建议'), findsOneWidget);
      expect(find.textContaining('计划审核并正式下达后系统会学习本次选择'), findsOneWidget);
      expect(find.textContaining('2026-08-11'), findsWidgets);
    },
  );

  testWidgets(
    'wizard hides missing-workshop banner when default workshop is prefilled',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionWorkshopTreeProvider.overrideWith(
              (ref) async => _workshops(),
            ),
            departmentPickerTreeProvider.overrideWith(
              (ref) async => const <DepartmentNode>[],
            ),
          ],
          child: MaterialApp(
            home: ProductionPlanWizardPage(
              entries: [
                ProductionPlanWizardEntry(
                  product: _product('product-10', '已学车间组件', 5),
                  qty: 5,
                  billDate: DateTime(2026, 8, 11),
                  departmentId: 'workshop-1',
                  workshopName: '注塑车间',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('中山市优腾电器有限公司'), findsOneWidget);
      expect(
        find.byKey(const Key('production-plan-wizard-missing-workshop')),
        findsNothing,
      );
    },
  );
}

List<DepartmentNode> _workshops() => [
  DepartmentNode(
    id: 'workshop-1',
    code: 'WS_ASSEMBLY_1',
    name: '装配一车间',
    level: '一级部门',
    children: const [],
  ),
  DepartmentNode(
    id: 'workshop-2',
    code: 'WS_INJECTION',
    name: '注塑车间',
    level: '一级部门',
    children: const [],
  ),
];

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
    productNo: 'V6-0001',
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
