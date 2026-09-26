// 供应方式（供料路线）的单一事实源 = 货品主档 `goods.source_type`（2026-09-16，
// ADR-070 §2.3 修订 / ADR-081 §5）。
//
// 2026-09-25 确认路线退役（ADR-102 修订）：进页对「主档能定路线」的行**自动确认**，
// 缺路线（主档空且无子层 → 服务端 REVIEW）的行红框空选、不能下单；下拉直改即存，
// 「确认并换桶」弹窗与右下「确认路线(N)」按钮退役。
//
// 这里守住的契约：
//  1. 进页只拉分析本身——**不再有第二趟记忆请求**（端点已删，发了就是 404）；
//  2. 进页自动确认恰好发一次 PUT /routes：只含「未确认且建议非空」的行
//     （已确认、REVIEW 不进），按显示值提交、一行都不多发；
//  3. REVIEW 行显示空下拉 + 红框（没有兜底委外、没有黄标——缺省值不再
//     假装已决定），选好即自动保存；
//  4. 下拉直改（含把确认过的路线改掉）立即保存，不弹确认框；保存同时
//     回写货品主档（服务端同事务），重进仍显示最新路线；
//  5. 没有 route 权限的人进页零写入，行保持建议值 + 红框只读。
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
  testWidgets('进页自动确认：只提交建议非空的未确认行，恰好一次', (tester) async {
    final harness = await _pump(tester);

    // m1/m3 主档来源=自制、m2=采购：进页即自动确认（服务端夹具回写确认）。
    expect(_value(tester, 'm1'), MaterialSupplyRoute.make);
    expect(_value(tester, 'm2'), MaterialSupplyRoute.buy);
    expect(_value(tester, 'm3'), MaterialSupplyRoute.make);
    // m4 已确认委外（确认压过建议），不进自动确认批次。
    expect(_value(tester, 'm4'), MaterialSupplyRoute.subcontract);
    // m5 主档来源为空（REVIEW → null）：红框空选，不自动确认。
    expect(_value(tester, 'm5'), isNull);
    expect(_pendingFrame(tester, 'm5'), isTrue);
    expect(_pendingFrame(tester, 'm1'), isFalse);

    // 自动确认整批一次 PUT：只含 m1/m2/m3（m4 已确认、m5 REVIEW 不进）。
    expect(harness.writes, hasLength(1));
    expect((harness.writes.single.data as Map<String, dynamic>)['decisions'], [
      {'actionGroupKey': 'a-m1', 'route': 'MAKE'},
      {'actionGroupKey': 'a-m2', 'route': 'BUY'},
      {'actionGroupKey': 'a-m3', 'route': 'MAKE'},
    ]);
    // 确认路线按钮已退役：悬浮区不再渲染。
    expect(
      find.byKey(const Key('material-analysis-create-routes')),
      findsNothing,
    );
    // /last-routes 已退役：一次都不能发（端点删了，发了就是 404）。
    expect(
      harness.requests.where((r) => r.path.contains('last-routes')),
      isEmpty,
    );
  });

  testWidgets('自动确认每纪元只发一次，保存回包不引发连环写', (tester) async {
    final harness = await _pump(tester);
    expect(harness.writes, hasLength(1));
    // 保存回包换新快照（version/fingerprint 已进位）后再 settle：纪元守卫
    // 挡住重复提交，不再有第二次 PUT。
    await tester.pumpAndSettle();
    expect(harness.writes, hasLength(1));
  });

  testWidgets('下拉直改即存：不弹确认框，立即保存并回写', (tester) async {
    final harness = await _pump(tester);
    final writesBefore = harness.writes.length;
    await _choose(tester, 'm1', '委外');
    await tester.pumpAndSettle();
    // 「确认并换桶」弹窗退役：选好即写，没有中间确认。
    expect(find.text('确认并换桶'), findsNothing);
    expect(harness.writes, hasLength(writesBefore + 1));
    final decisions =
        (harness.writes.last.data as Map<String, dynamic>)['decisions'];
    expect(decisions, [
      {'actionGroupKey': 'a-m1', 'route': 'SUBCONTRACT'},
    ]);
    expect(_value(tester, 'm1'), MaterialSupplyRoute.subcontract);
    expect(_pendingFrame(tester, 'm1'), isFalse);
  });

  testWidgets('REVIEW 红框行：选好供应方式即自动保存', (tester) async {
    final harness = await _pump(tester);
    expect(_value(tester, 'm5'), isNull, reason: '主档来源为空显示空选，不再兜底委外');
    await _choose(tester, 'm5', '采购');
    await tester.pumpAndSettle();
    expect(harness.writes, hasLength(2));
    final decisions =
        (harness.writes.last.data as Map<String, dynamic>)['decisions'];
    expect(decisions, [
      {'actionGroupKey': 'a-m5', 'route': 'BUY'},
    ]);
    expect(_value(tester, 'm5'), MaterialSupplyRoute.buy);
    expect(_pendingFrame(tester, 'm5'), isFalse);
  });

  testWidgets('没有 route 权限：进页零写入，建议值只读展示', (tester) async {
    final harness = await _pump(tester, routePermission: false);
    expect(harness.writes, isEmpty, reason: '无权限不自动确认、不写任何东西');
    // 无权限时路线格是只读文本（没有下拉可改），建议路线照常显示，
    // 行仍是「路线待确认」（进度徽章红字指路）。
    expect(_pendingFrame(tester, 'm1'), isFalse, reason: '只读格没有红框框选');
    expect(_routeTextNear(tester, 'm1'), contains('自制'));
    expect(_routeTextNear(tester, 'm5'), contains('—'));
  });
}

Finder _dropdown(String id) =>
    find.byKey(ValueKey('material-route-dropdown-$id'));

MaterialSupplyRoute? _value(WidgetTester tester, String id) {
  final value = tester.widget<UtenDropdownField>(_dropdown(id)).value;
  return value == null ? null : MaterialSupplyRoute.values.byName(value);
}

/// 路线格有没有被红框框住（未确认供应方式）。
bool _pendingFrame(WidgetTester tester, String id) =>
    find.byKey(ValueKey('material-route-pending-$id')).evaluate().isNotEmpty;

/// 只读路线格里显示的文本（无权限时路线格没有下拉）。
String _routeTextNear(WidgetTester tester, String id) {
  final row = find.byKey(ValueKey('material-table-row-$id'));
  final texts = tester
      .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
      .map((text) => text.data ?? '')
      .toList();
  return texts.join(' ');
}

Future<void> _choose(WidgetTester tester, String id, String label) async {
  await tester.ensureVisible(_dropdown(id));
  await tester.tap(_dropdown(id));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text(label).last);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<_Harness> _pump(
  WidgetTester tester, {
  _Harness? existing,
  bool routePermission = true,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final harness = existing ?? _Harness();
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
        currentPermissionsProvider.overrideWithValue({
          Perm.productionMaterialAnalysisView,
          if (routePermission) Perm.productionMaterialAnalysisRoute,
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
    // 主档来源为空：服务端给 REVIEW，前端解析成 null → 红框空选。
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
