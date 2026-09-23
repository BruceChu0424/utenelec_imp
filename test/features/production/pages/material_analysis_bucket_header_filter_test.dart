// 「下达车间」桶详情页（物料分析可安排桶）的表头快速筛选回归测试。
//
// 2026-09-11 用户截图反馈：同一张表里「生产车间/负责人/状态」有下拉小箭头，
// 「类型」「货品」没有。2026-09-22 桶表改成只读的 MasterDataTableView 后
// (ADR-102 §十一)，「类型」列随之退役，文本列(物料名称 / 编号 / 颜色 / 单位 /
// 供应方式)与进度列都按单元格文本分桶——本测钉住：文本列有筛选箭头、数量列
// 没有；货品按货品名分桶(同名货品合并成一桶)且能收敛行；编号逐行分桶。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
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

    // 文本列有筛选箭头，数量列(需求量)没有。
    expect(_filterArrowOf('物料名称'), findsOneWidget);
    expect(_filterArrowOf('编号'), findsOneWidget);
    expect(_filterArrowOf('需求量'), findsNothing);

    // 三行：甲产品 / 乙子件 / 甲产品。
    expect(find.text('甲产品'), findsNWidgets(2));
    expect(find.text('乙子件'), findsOneWidget);

    // 编号筛选(逐行一桶)：选「P-beta」后只剩乙子件。
    await tester.tap(_headerCell('编号'));
    await tester.pumpAndSettle();
    expect(find.text('P-alpha (1)'), findsOneWidget);
    await tester.tap(find.text('P-beta (1)'));
    await tester.pumpAndSettle();
    expect(find.text('甲产品'), findsNothing);
    expect(find.text('乙子件'), findsOneWidget);

    // 撤回「所有」，换成货品筛选：同名货品合并一桶(不按行 id 各成一桶)。
    await tester.tap(_headerCell('P-beta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('所有'));
    await tester.pumpAndSettle();
    expect(find.text('甲产品'), findsNWidgets(2));

    await tester.tap(_headerCell('物料名称'));
    await tester.pumpAndSettle();
    expect(find.text('甲产品 (2)'), findsOneWidget);
    expect(find.text('乙子件 (1)'), findsOneWidget);
    await tester.tap(find.text('甲产品 (2)'));
    await tester.pumpAndSettle();
    // 两行数据 + 表头高亮显示的当前筛选值(激活筛选看得见)。
    expect(find.text('甲产品'), findsNWidgets(3));
    expect(_headerCell('甲产品'), findsOneWidget);
    expect(find.text('乙子件'), findsNothing);
  });
}

/// 表头格：MasterDataTableView 的列头是「标签 + 箭头」的 InkWell，按标签文本定位。
Finder _headerCell(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first;

Finder _filterArrowOf(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(InkWell)),
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
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final data = switch (request.path) {
          '/master/warehouses/dict' => [
            {'id': 'warehouse-1', 'name': '主仓'},
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
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        departmentRepositoryProvider.overrideWithValue(_DepartmentRepository()),
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
