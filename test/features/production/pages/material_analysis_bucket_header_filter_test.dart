import '../../../support/production_person_reference_fixture.dart';
import '../../../support/table_cell_geometry.dart';
// 「下达车间」桶详情页（物料分析可安排桶）的表头快速筛选回归测试。
//
// 2026-09-11 用户截图反馈：同一张表里「生产车间/负责人/状态」有下拉小箭头，
// 「类型」「货品」没有。2026-09-22 桶表改成只读的 MasterDataTableView 后
// (ADR-102 §十一)，「类型」列随之退役，文本列(物料名称 / 编号 / 颜色 / 单位 /
// 供应方式)与进度列都按单元格文本分桶。当前数量列使用精确值数值条件；文本
// 列按原值分桶，货品同名合并成一桶、编号逐行分桶，筛选均能收敛行。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/models/department_node.dart';
import 'package:uten_imp/shared/repositories/department_repository.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  testWidgets('下达车间页「物料名称」「编号」有表头筛选，且能收敛行', (tester) async {
    await _pump(tester);
    await _openWorkshopBucket(tester);

    // 文本列按原值分桶，数量列使用精确值数值条件。
    final quantityLabel = AppLocalizations.of(
      tester.element(_bucketTable()),
    ).materialRequired;
    expect(_filterArrowOf(tester, '物料名称'), findsOneWidget);
    expect(_filterArrowOf(tester, '编号'), findsOneWidget);
    expect(_headerColumn(tester, quantityLabel), findsOneWidget);
    expect(_filterArrowOf(tester, quantityLabel), findsOneWidget);
    final table = tester.widget<MasterDataTableView<dynamic>>(_bucketTable());
    final quantityColumn = table.columns.firstWhere(
      (column) => column.key == 'requiredQty',
    );
    expect(quantityColumn.type, 'number');
    expect(quantityColumn.info, contains('原始来源需求'));

    // Exercise the private row's exact numeric projection through its real UI,
    // rather than widening its contravariant callback to Object/dynamic.
    await tester.tap(_headerText(tester, quantityLabel).hitTestable());
    await tester.pumpAndSettle();
    final quantityInput = find.byKey(const Key('uten-column-keyword-input'));
    await tester.enterText(quantityInput, '>9');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('甲产品'), findsNWidgets(2));
    expect(find.text('乙子件'), findsOneWidget);
    await tester.tap(_headerText(tester, quantityLabel).hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.text('所有').last);
    await tester.pumpAndSettle();

    // 三行：甲产品 / 乙子件 / 甲产品。
    expect(find.text('甲产品'), findsNWidgets(2));
    expect(find.text('乙子件'), findsOneWidget);

    // 编号筛选(逐行一桶)：选「P-beta」后只剩乙子件。
    expect(
      table.facets['goodsCode']!.map((bucket) => (bucket.value, bucket.count)),
      unorderedEquals([('P-alpha', 1), ('P-beta', 1), ('P-gamma', 1)]),
    );
    await tester.tap(_headerText(tester, '编号').hitTestable());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('uten-column-keyword-input')), findsOneWidget);
    expect(find.text('P-alpha (1)'), findsOneWidget);
    await tester.tap(find.text('P-beta (1)'));
    await tester.pumpAndSettle();
    expect(find.text('甲产品'), findsNothing);
    expect(find.text('乙子件'), findsOneWidget);

    // 撤回「所有」，换成货品筛选：同名货品合并一桶(不按行 id 各成一桶)。
    await tester.tap(_headerText(tester, '编号').hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.text('所有'));
    await tester.pumpAndSettle();
    expect(find.text('甲产品'), findsNWidgets(2));

    await tester.tap(_headerText(tester, '物料名称').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('甲产品 (2)'), findsOneWidget);
    expect(find.text('乙子件 (1)'), findsOneWidget);
    await tester.tap(find.text('甲产品 (2)'));
    await tester.pumpAndSettle();
    // 两行数据 + 表头高亮显示的当前筛选值(激活筛选看得见)。
    expect(find.text('甲产品'), findsNWidgets(3));
    expect(_headerCell(tester, '物料名称'), findsOneWidget);
    expect(
      find.descendant(
        of: _headerCell(tester, '物料名称'),
        matching: find.text('甲产品'),
      ),
      findsOneWidget,
    );
    expect(find.text('乙子件'), findsNothing);
  });
}

/// Bind to this bucket's actual column chrome. Header search now also renders
/// field labels, and row values may equal an active header's display value.
Finder _bucketTable() => find.byWidgetPredicate(
  (widget) =>
      widget is MasterDataTableView<Object?> &&
      widget.tableKey ==
          'features.production.pages.material_analysis_bucket_detail.MaterialAnalysisBucketPageState._bucketTable.1',
);

Finder _headerColumn(WidgetTester tester, String label) {
  // 2026-11 a78fa7ce4 起列宽手柄搬进表头行上层 overlay，不再是表头格后代；
  // 表头格改锚筛选格自身的稳定 key（列 key）——激活筛选时表头文字会换成桶值
  // （如只显示「甲产品」），按文字锚定会找丢。
  final table = tester.widget<MasterDataTableView<dynamic>>(_bucketTable());
  final column = table.columns.firstWhere((c) => c.label == label);
  return tableCellFrame(
    find.descendant(
      of: _bucketTable(),
      matching: find.byKey(ValueKey('master-column-filter-${column.key}')),
    ),
  );
}

Finder _headerCell(WidgetTester tester, String label) => find
    .descendant(
      of: _headerColumn(tester, label),
      matching: find.byType(InkWell),
    )
    .first;

/// The header center can belong to its separate information button. Hit the
/// actual visible label to open the filter, preserving the info action too.
Finder _headerText(WidgetTester tester, String label) => find
    .descendant(of: _headerCell(tester, label), matching: find.byType(Text))
    .first;

Finder _filterArrowOf(WidgetTester tester, String label) => find.descendant(
  of: _headerColumn(tester, label),
  matching: find.byIcon(Icons.arrow_drop_down_rounded),
);

Future<void> _openWorkshopBucket(WidgetTester tester) async {
  final entry = find.byKey(const Key('material-analysis-entry-workshop'));
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fixtureDepartmentRepository = _DepartmentRepository();
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) async {
        if (await resolveProductionPersonReferenceFixture(
          request,
          handler,
          departments: fixtureDepartmentRepository.tree,
        )) {
          return;
        }
        final data = switch (request.path) {
          '/business-references/warehouses' => [
            {'id': 'warehouse-1', 'name': '主仓', 'selectableForNew': true},
          ],
          '/production/material-analyses/analysis-1' => _analysis(),
          '/production/material-analyses/sales-candidates' => {
            'items': <Object>[],
            'page': 1,
            'size': 20,
            'total': 0,
            'totalPages': 1,
          },
          _ => <Object>[],
        };
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  final api = ApiClient(dio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        apiClientProvider.overrideWithValue(api),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        departmentRepositoryProvider.overrideWithValue(
          fixtureDepartmentRepository,
        ),
        materialAnalysisWarehousePrefsProvider.overrideWith(
          _WarehousePrefs.new,
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionMaterialAnalysisView,
          Perm.productionMaterialAnalysisNotify,
          Perm.productionMaterialAnalysisGenerate,
        }),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProductionMaterialAnalysisPage(
          seed: ProductionMaterialAnalysisSeed(
            analysisId: 'analysis-1',
            warehouseId: 'warehouse-1',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

class _DepartmentRepository implements DepartmentRepository {
  @override
  Future<List<DepartmentNode>> tree() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WarehousePrefs extends MaterialAnalysisWarehousePrefsNotifier {
  @override
  MaterialAnalysisWarehousePrefs build() =>
      const MaterialAnalysisWarehousePrefs();
  @override
  Future<void> syncNow() async {}
  @override
  void update(MaterialAnalysisWarehousePrefs value) {
    state = value.normalized();
  }
}

Map<String, dynamic> _analysis() => {
  'analysisId': 'analysis-1',
  'status': 'ACTIVE',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse-1',
  'warehouseIds': ['warehouse-1'],
  'allowedActions': ['VIEW', 'NOTIFY_SUPPLY', 'PLAN_PREVIEW', 'GENERATE_PLAN'],
  'products': [
    _product('alpha', '甲产品', 'STOCK'),
    _product('beta', '乙子件', 'MAKE_COMPONENT'),
    // 同名货品的第二条计划行：货品桶必须合并成一桶(计数 2)。
    _product('gamma', '甲产品', 'STOCK'),
  ],
  'flatMaterials': <Object>[],
  'warehouses': [
    {'warehouseId': 'warehouse-1', 'warehouseName': '主仓'},
  ],
};

Map<String, dynamic> _product(String id, String name, String sourceType) => {
  'analysisLineId': id,
  'sourceType': sourceType,
  'goodsId': 'goods-$id',
  'goodsCode': 'P-$id',
  'goodsName': name,
  'requestedQty': 10,
  'remainingQty': 10,
  'readyNowQty': 0,
  'canSchedule': true,
  'maxSchedulableQty': 10,
};
