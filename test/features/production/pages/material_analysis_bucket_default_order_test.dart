// 三个分桶详情页（下达车间 / 采购 / 委外）的默认排序回归测试。
//
// 2026-10-09 用户口径「默认按进度排序，最接近完成的在上面」：有单据链阶段的行
// 按「本链还差几步」升序（生产中完成比高的在前），没有阶段事实的行（等待下达/
// 阻塞/只读）排在有阶段事实的行之后、彼此保持投影原序。本测用下达车间桶的
// 进行中清单钉住顺序：生产中80% → 生产中20% → 齐套可开工 → 等待物料 → 计划待审核。
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
  testWidgets('桶详情默认按进度排序：最接近完成的在上面，同一步完成比高的在前', (tester) async {
    await _pump(tester);
    await _openWorkshopBucket(tester);
    // 切到「进行中」清单——五条产品行都有真实执行阶段。
    await tester.tap(find.text('进行中').first);
    await tester.pumpAndSettle();

    // 投影原序是故意倒着放的（待审 → 等料 → 齐套 → 20% → 80%）；
    // 默认排序必须把它翻成「离完成越近越靠上」。
    final names = ['戊八十', '丁二十', '丙齐套', '乙等料', '甲待审'];
    var previous = -1.0;
    for (final name in names) {
      final row = find.text(name);
      expect(row, findsOneWidget, reason: '$name 应在进行中清单里');
      final top = tester.getTopLeft(row).dy;
      expect(
        top,
        greaterThan(previous),
        reason: '$name 应排在上一行（离完成更远的）之下；期望顺序 ${names.join(' → ')}',
      );
      previous = top;
    }
  });
}

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
  // 投影原序故意按「离完成最远 → 最近」排放；默认排序应整体倒转。
  'products': [
    _product('submitted', '甲待审', 'SUBMITTED'),
    _product('waiting', '乙等料', 'WAITING'),
    _product('ready', '丙齐套', 'READY'),
    _product('p20', '丁二十', 'IN_PROGRESS', reported: 2),
    _product('p80', '戊八十', 'IN_PROGRESS', reported: 8),
  ],
  'flatMaterials': <Object>[],
  'warehouses': [
    {'warehouseId': 'warehouse-1', 'warehouseName': '主仓'},
  ],
};

Map<String, dynamic> _product(
  String id,
  String name,
  String executionStatus, {
  double? reported,
}) => {
  'analysisLineId': id,
  'sourceType': 'STOCK',
  'goodsId': 'goods-$id',
  'goodsCode': 'P-$id',
  'goodsName': name,
  'requestedQty': 10,
  'remainingQty': 10,
  'readyNowQty': 0,
  'canSchedule': true,
  'maxSchedulableQty': 10,
  'planExecutionStatus': executionStatus,
  'planExecutionPlannedQty': 10,
  'planExecutionReportedQty': ?reported,
};
