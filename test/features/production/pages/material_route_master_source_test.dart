// 供应方式（供料路线）的单一事实源 = 货品主档 `goods.source_type`（2026-09-16，
// ADR-070 §2.3 修订 / ADR-081 §5）。
//
// 2026-09-25 确认路线退役(ADR-102 修订)：「主档能定路线」的行自动确认，
// 缺路线（主档空且无子层 → 服务端 REVIEW）的行红框空选、不能下单；下拉直改即存，
// 「确认并换桶」弹窗与右下「确认路线(N)」按钮退役。
//
// 2026-09-27(ADR-102 修订)：自动确认挪到服务端——新建 / 刷新分析的同一次重算里
// 直接确认，页面不再自己补发 PUT /routes、不再盖全屏遮罩。打开已有分析时，详情报
// `pendingAutoConfirmRouteCount` > 0 才静默刷新一次(POST /preview)，由服务端确认。
//
// 这里守住的契约：
//  1. 进页只拉分析本身——**不再有第二趟记忆请求**（端点已删，发了就是 404）；
//  2. 详情报待确认：恰好一次静默刷新(完整来源 + 版本/指纹)，零 PUT /routes、零遮罩，
//     回包的自动确认条数轻提示；同一纪元不重复、回包仍报待确认也不连环刷新；
//  3. 详情不报待确认：页面自己一条都不确认(零写入)；
//  4. REVIEW 行显示空下拉 + 红框(没有兜底委外、没有黄标)，选好即自动保存；
//  5. 下拉直改(含把确认过的路线改掉)立即保存(PUT /routes)，不弹确认框；
//  6. 没有 route 权限的人进页零写入，行保持建议值只读展示。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  testWidgets('详情报待确认：静默刷新一次由服务端确认，零 PUT、零遮罩', (tester) async {
    final harness = await _pump(tester);

    // 服务端在刷新里确认了 m1/m3(自制)、m2(采购)。
    expect(_value(tester, 'm1'), MaterialSupplyRoute.make);
    expect(_value(tester, 'm2'), MaterialSupplyRoute.buy);
    expect(_value(tester, 'm3'), MaterialSupplyRoute.make);
    // m4 已确认委外(确认压过建议)。
    expect(_value(tester, 'm4'), MaterialSupplyRoute.subcontract);
    // m5 主档来源为空(REVIEW → null)：红框空选，服务端也不确认。
    expect(_value(tester, 'm5'), isNull);
    expect(_pendingFrame(tester, 'm5'), isTrue);
    expect(_pendingFrame(tester, 'm1'), isFalse);

    expect(harness.writes, isEmpty, reason: '页面不再为自动确认发 PUT /routes');
    expect(harness.previews, hasLength(1), reason: '恰好一次静默刷新');
    final body = harness.previews.single.data as Map<String, dynamic>;
    expect(body['analysisId'], 'analysis');
    expect(body['version'], 3);
    expect(body['fingerprint'], 'a' * 64);
    expect(body['sources'], hasLength(1), reason: '与手动刷新同一入口：带完整来源');
    // 没有任何全屏遮罩(自动确认不走「正在确认物料路线」)。
    expect(
      find.byKey(const Key('material-analysis-action-busy')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('material-analysis-route-auto-confirming')),
      findsNothing,
      reason: '刷新完成后小提示撤掉',
    );
    expect(_notices(tester), contains('已按货品档案自动确认 3 条供应方式'));
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

  testWidgets('静默刷新每纪元只发一次，回包仍报待确认也不连环刷新', (tester) async {
    final harness = await _pump(tester, stillPendingAfterRefresh: true);
    expect(harness.previews, hasLength(1));
    await tester.pumpAndSettle();
    expect(harness.previews, hasLength(1));
    expect(harness.writes, isEmpty);
  });

  testWidgets('详情不报待确认：页面自己一条都不确认', (tester) async {
    final harness = await _pump(tester, pending: 0);
    expect(harness.writes, isEmpty);
    expect(harness.previews, isEmpty);
    // 未确认行照常显示主档建议(服务端已在新建时确认的分析不会出现这种行，
    // 这里只验证页面不再自作主张)。
    expect(_value(tester, 'm1'), MaterialSupplyRoute.make);
  });

  testWidgets('下拉直改即存：不弹确认框，立即保存并回写', (tester) async {
    final harness = await _pump(tester);
    expect(harness.writes, isEmpty);
    await _choose(tester, 'm1', '委外');
    await tester.pumpAndSettle();
    // 「确认并换桶」弹窗退役：选好即写，没有中间确认。
    expect(find.text('确认并换桶'), findsNothing);
    expect(harness.writes, hasLength(1));
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
    expect(harness.writes, hasLength(1));
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
    expect(harness.writes, isEmpty, reason: '无权限不确认、不写任何东西');
    expect(harness.previews, isEmpty, reason: '无确认能力不静默刷新');
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

/// 页面发出的顶部通知文案(测试壳没有挂通知宿主，直接读队列)。
List<String> _notices(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(ProductionMaterialAnalysisPage)),
).read(appNotificationProvider).map((notice) => notice.message).toList();

Future<void> _choose(WidgetTester tester, String id, String label) async {
  await tester.ensureVisible(_dropdown(id));
  await tester.tap(_dropdown(id));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text(label).last);
  await tester.pump(const Duration(milliseconds: 300));
}

/// 服务端自动确认的夹具：与 MaterialAnalysisRouteAutoConfirm 同口径的简化版——
/// 未确认且主档建议非空(非 REVIEW)的操作组按建议确认，返回确认的组数。
int _serverAutoConfirm(Map<String, dynamic> json) {
  var confirmed = 0;
  for (final row
      in (json['flatMaterials'] as List).cast<Map<String, dynamic>>()) {
    if (row['routeConfirmed'] == true || row['sourceSuggestion'] == null) {
      continue;
    }
    row['sourceConfirmed'] = row['sourceSuggestion'];
    row['routeConfirmed'] = true;
    confirmed++;
  }
  return confirmed;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  bool routePermission = true,
  int pending = 3,
  bool stillPendingAfterRefresh = false,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final harness = _Harness()
    ..data['pendingAutoConfirmRouteCount'] = routePermission ? pending : 0;
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
        } else if (request.method == 'POST' &&
            request.path.endsWith('/preview')) {
          // 服务端刷新：同一次重算里按货品档案确认(同事务回写主档)，
          // 版本只涨一次，回包带本次确认条数。
          harness.data =
              jsonDecode(jsonEncode(harness.data)) as Map<String, dynamic>;
          harness.data['autoConfirmedRouteCount'] = _serverAutoConfirm(
            harness.data,
          );
          harness.data['pendingAutoConfirmRouteCount'] =
              stillPendingAfterRefresh ? 1 : 0;
          harness.data['version'] = (harness.data['version'] as int) + 1;
          harness.data['fingerprint'] = 'b' * 64;
          result = harness.data;
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
          harness.data['autoConfirmedRouteCount'] = 0;
          harness.data['pendingAutoConfirmRouteCount'] = 0;
          harness.data['version'] = (harness.data['version'] as int) + 1;
          harness.data['fingerprint'] = 'c' * 64;
          result = harness.data;
        } else if (request.path == '/production/material-analyses/analysis') {
          // 详情从不带「本次自动确认条数」。
          result = {...harness.data, 'autoConfirmedRouteCount': 0};
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
          Perm.productionMaterialAnalysisRefresh,
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
  List<RequestOptions> get previews => requests
      .where(
        (request) =>
            request.method == 'POST' && request.path.endsWith('/preview'),
      )
      .toList();
}

Map<String, dynamic> _analysis() => {
  'analysisId': 'analysis',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse',
  'warehouseIds': ['warehouse'],
  'status': 'ACTIVE',
  'allowedActions': ['VIEW', 'CONFIRM_ROUTES', 'REFRESH'],
  'products': [
    {
      'analysisLineId': 'product',
      'sourceType': 'STOCK',
      'sourceRef': 'STOCK-1',
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
