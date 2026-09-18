// 供应方式（供料路线）的单一事实源 = 货品主档 `goods.source_type`（2026-09-16，
// ADR-070 §2.3 修订 / ADR-081 §5）。
//
// 本文件取代原 `material_route_memory_test.dart`：那套「按历史分析推导上次确认
// 路线」的前端记忆（`GET /last-routes` + 本地缓存 + 会话作用域隔离 + 迟到响应
// 代际防护）整套退役——用户实测「我在物料分析准备页把供应方式改了，下次进来还是
// 老的」，根因就是确认只写分析行、货品主档从没更新，而新分析的建议路线又是从主档
// 算出来的。现在确认路线同事务回写主档，建议路线随分析快照下发。
//
// 这里守住的契约：
//  1. 进页只拉分析本身——**不再有第二趟记忆请求**（端点已删，发了就是 404）；
//  2. 显示的路线优先级 = 本地草稿 > 已确认 > 主档建议 > 兜底委外；
//  3. 主档来源为空（服务端 REVIEW → 前端 null）的行显示的委外只是缺省值，
//     必须挂黄标提醒核对，不能看着像「已决定」；
//  4. 改下拉只是本地草稿，勾选 + 点「确认路线」才提交，原因不强制；
//  5. 提交的 decisions 逐字等于表里显示的那几行。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  testWidgets('建议路线直接来自主档快照，进页不再发第二趟记忆请求', (tester) async {
    final harness = await _pump(tester);

    // m1/m3 主档来源=自制、m2=采购、m4 已确认委外（已确认压过建议）、
    // m5 主档来源为空（服务端 REVIEW → 前端 null）只能兜底委外。
    expect(_value(tester, 'm1'), MaterialSupplyRoute.make);
    expect(_value(tester, 'm2'), MaterialSupplyRoute.buy);
    expect(_value(tester, 'm3'), MaterialSupplyRoute.make);
    expect(_value(tester, 'm4'), MaterialSupplyRoute.subcontract);
    expect(_value(tester, 'm5'), MaterialSupplyRoute.subcontract);

    // /last-routes 已退役：一次都不能发（端点删了，发了就是 404）。
    expect(
      harness.requests.where((r) => r.path.contains('last-routes')),
      isEmpty,
    );
    expect(harness.writes, isEmpty, reason: '打开页面不写任何东西');
  });

  testWidgets('主档来源为空的行：兜底委外要挂黄标，不能看着像已决定', (tester) async {
    await _pump(tester);
    // m5 主档没给来源，显示的委外只是硬回退；m1 有主档建议，不挂黄标。
    expect(_hintIconNear(tester, 'm5'), isTrue);
    expect(_hintIconNear(tester, 'm1'), isFalse);
  });

  testWidgets('改下拉只是本地草稿，勾选并确认后才提交，且不强制填原因', (tester) async {
    final harness = await _pump(tester);
    await _choose(tester, 'm1', '委外');
    await _select(tester, 'm2');
    expect(_value(tester, 'm1'), MaterialSupplyRoute.subcontract);
    expect(harness.writes, isEmpty, reason: '改下拉不落盘');

    await tester.tap(find.byKey(const Key('material-analysis-create-routes')));
    await tester.pumpAndSettle();
    // 原因不强制：不弹任何补原因的对话框。
    expect(find.byType(AlertDialog), findsNothing);
    expect(harness.writes, hasLength(1));
    expect(
      (harness.writes.single.data as Map<String, dynamic>)['decisions'],
      [
        {'actionGroupKey': 'a-m1', 'route': 'SUBCONTRACT'},
        // m2 没被改过下拉：按它的主档建议（采购）原样提交。
        {'actionGroupKey': 'a-m2', 'route': 'BUY'},
      ],
      reason: '提交的内容逐字等于表里显示的那两行',
    );
    // 未参与本次确认的行保持原样。
    expect(_value(tester, 'm3'), MaterialSupplyRoute.make);
    expect(_value(tester, 'm4'), MaterialSupplyRoute.subcontract);
  });

  testWidgets('只勾选不改下拉：按当前显示的路线提交，一行都不多发', (tester) async {
    final harness = await _pump(tester);
    await _select(tester, 'm1');
    await tester.pumpAndSettle();
    expect(harness.writes, isEmpty);
    await tester.tap(find.byKey(const Key('material-analysis-create-routes')));
    await tester.pumpAndSettle();
    expect(
      (harness.writes.single.data as Map<String, dynamic>)['decisions'],
      [
        {'actionGroupKey': 'a-m1', 'route': 'MAKE'},
      ],
    );
  });
}

Finder _dropdown(String id) =>
    find.byKey(ValueKey('material-route-dropdown-$id'));

MaterialSupplyRoute? _value(WidgetTester tester, String id) {
  final value = tester.widget<UtenDropdownField>(_dropdown(id)).value;
  return value == null ? null : MaterialSupplyRoute.values.byName(value);
}

/// 路线格旁边有没有「主档来源为空，请核对」的黄标提示图标。
bool _hintIconNear(WidgetTester tester, String id) => find
    .byKey(ValueKey('material-route-blank-source-$id'))
    .evaluate()
    .isNotEmpty;

Future<void> _choose(WidgetTester tester, String id, String label) async {
  await tester.ensureVisible(_dropdown(id));
  await tester.tap(_dropdown(id));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text(label).last);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _select(WidgetTester tester, String id) async {
  // 表格横滚后前导勾选格会多渲染一份钉在视口左缘的副本
  // (UtenFrozenLeadingColumn)，两份共享同一 onChanged，取第一份即可。
  final checkbox = find
      .descendant(
        of: find.byKey(ValueKey('material-table-row-$id')),
        matching: find.byType(Checkbox),
      )
      .first;
  await tester.ensureVisible(checkbox);
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
}

Future<_Harness> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final harness = _Harness();
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) async {
        harness.requests.add(request);
        dynamic result = <String, dynamic>{};
        if (request.path.endsWith('/warehouses/dict')) {
          result = [
            {'id': 'warehouse', 'name': '主仓'},
          ];
        } else if (request.method == 'PUT' &&
            request.path.endsWith('/routes')) {
          // 服务端确认路线时同事务回写货品主档，并把本行的 sourceSuggestion
          // 对齐成确认值（否则下一次刷新会把确认当成「主档事实变更」清掉）。
          final decisions =
              (request.data as Map<String, dynamic>)['decisions'] as List;
          harness.data =
              jsonDecode(jsonEncode(harness.data)) as Map<String, dynamic>;
          for (final decision in decisions.cast<Map<String, dynamic>>()) {
            final row = (harness.data['flatMaterials'] as List)
                .cast<Map<String, dynamic>>()
                .singleWhere(
                  (row) => row['actionGroupKey'] == decision['actionGroupKey'],
                );
            row['sourceConfirmed'] = decision['route'];
            row['sourceSuggestion'] = decision['route'];
            row['routeConfirmed'] = true;
          }
          harness.data['version'] = (harness.data['version'] as int) + 1;
          harness.data['fingerprint'] = 'c' * 64;
          result = harness.data;
        } else if (request.path == '/production/material-analyses/analysis') {
          result = harness.data;
        } else if (request.path.endsWith('/sales-candidates')) {
          result = {
            'items': <Object>[],
            'page': 1,
            'size': 20,
            'total': 0,
            'totalPages': 0,
          };
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: result,
          ),
        );
      },
    ),
  );
  final api = ApiClient(dio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(const {
          Perm.productionMaterialAnalysisView,
          Perm.productionMaterialAnalysisRoute,
        }),
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        materialAnalysisWarehousePrefsProvider.overrideWith(_Prefs.new),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProductionMaterialAnalysisPage(
          seed: ProductionMaterialAnalysisSeed(
            analysisId: 'analysis',
            warehouseId: 'warehouse',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return harness;
}

class _Prefs extends MaterialAnalysisWarehousePrefsNotifier {
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

class _Harness {
  Map<String, dynamic> data = _analysis();
  final List<RequestOptions> requests = [];
  List<RequestOptions> get writes =>
      requests.where((request) => request.method == 'PUT').toList();
}

Map<String, dynamic> _analysis() => {
  'analysisId': 'analysis',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse',
  'warehouseIds': ['warehouse'],
  'status': 'ACTIVE',
  'allowedActions': ['VIEW', 'CONFIRM_ROUTES'],
  'products': [
    {
      'analysisLineId': 'product',
      'sourceType': 'STOCK',
      'goodsId': 'root-goods',
      'goodsName': '测试产品',
      'requestedQty': 10,
      'remainingQty': 10,
    },
  ],
  'flatMaterials': [
    _material('m1', 'MAKE'),
    _material('m2', 'BUY'),
    _material('m3', 'MAKE'),
    // 已确认的路线压过主档建议。
    _material('m4', 'BUY')
      ..['sourceConfirmed'] = 'SUBCONTRACT'
      ..['routeConfirmed'] = true,
    // 主档来源为空：服务端给 REVIEW，前端解析成 null，只能兜底委外并挂黄标。
    _material('m5', null)..['goodsId'] = 'new-goods',
  ],
};

Map<String, dynamic> _material(String id, String? suggestion) => {
  'materialLineId': id,
  'analysisLineId': 'product',
  'nodeKey': id,
  'actionGroupKey': 'a-$id',
  'goodsId': 'shared-$id',
  'goodsName': '物料 $id',
  'goodsCode': id,
  'level': 1,
  'path': ['测试产品', '物料 $id'],
  'requiredQty': 10,
  'shortageQty': 10,
  'demandSupplyGapQty': 10,
  'additionalSupplyRecommendedQty': 10,
  'sourceSuggestion': suggestion,
  'routeConfirmed': false,
  'actionable': true,
};
