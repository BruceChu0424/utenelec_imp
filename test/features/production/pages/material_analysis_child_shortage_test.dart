// ADR-117 下单后查子层：弹窗「下层物料还不够」→「补下层物料」页 → 一键下单；
// 页面顶部提示条(已下单的件下层还缺 / 车间在催)。
//
// 守的是口径：
// - 只在下单 / 追加**成功之后**问，而且只问刚下单的件的下层(别的件缺料由提示条常驻提醒)；
// - 没下过的列成「下单」、下过的列成「追加」，数量按缺口预填；
// - 补料页用的是主表同一份输入与同一条提交编排：下完回到主表，下单数量已锁成累计已下单量；
// - 取消勾选的行不提交；没定供应方式的行不能勾，并说出原因；
// - 车间在催时提示条变红、补料页给那几行挂「车间在催」，下完立即请求核对办结。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

const _permissions = {
  Perm.productionMaterialAnalysisView,
  Perm.productionMaterialAnalysisRoute,
  Perm.productionMaterialAnalysisNotify,
  Perm.productionMaterialAnalysisGenerate,
};

final List<({String method, String path, Map<String, dynamic>? body})>
requests = [];

String _groupKey(String line) => 'NODE|a-$line|$line';

Finder _productCheckbox(String product) => find.descendant(
  of: find.byKey(ValueKey('material-bom-product-$product')),
  matching: find.byType(Checkbox),
);

Finder _rowCheckbox(String line) => find.descendant(
  of: find.byKey(ValueKey('material-table-row-$line')),
  matching: find.byType(Checkbox),
);

Finder _appendQty(String line) =>
    find.byKey(ValueKey('material-analysis-append-qty-${_groupKey(line)}'));

Finder _pageLine(String line) =>
    find.byKey(ValueKey('child-shortage-line-${_groupKey(line)}'));

Future<void> _check(WidgetTester tester, Finder checkbox) async {
  tester.widget<Checkbox>(checkbox).onChanged!(true);
  await tester.pump();
}

/// 等假后端应答与分段编排跑完(期间没有动画帧, pumpAndSettle 会提前返回)。
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

/// 主表「下单(N)」→ 确认框「下达」。
Future<void> _submitMainTable(WidgetTester tester) async {
  requests.clear();
  await tester.tap(find.byKey(const Key('material-analysis-submit-orders')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: find.byType(AlertDialog), matching: find.text('下达')),
  );
  await _drain(tester);
}

/// 补料页「一键下单」→ 确认框「下达」。
Future<void> _submitShortagePage(WidgetTester tester) async {
  requests.clear();
  await tester.tap(find.byKey(const Key('child-shortage-submit')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: find.byType(AlertDialog), matching: find.text('下达')),
  );
  await _drain(tester);
}

List<({String method, String path, Map<String, dynamic>? body})> _writes() => [
  for (final request in requests)
    if (request.path.endsWith('/notify') ||
        request.path.endsWith('/issue-plans'))
      request,
];

double? _notifyQty(Map<String, dynamic>? body, String line) {
  for (final raw in (body?['quantities'] as List? ?? const [])) {
    final quantity = raw as Map;
    if (quantity['actionGroupKey'] == 'a-$line') {
      return (quantity['qty'] as num).toDouble();
    }
  }
  return null;
}

void main() {
  testWidgets('下单父件后只点名它自己下层缺的料；稍后再说后提示条常驻', (tester) async {
    await _pump(tester);
    // 下单前：只有已下单的委外件 m-p 下面缺 1 种，提示条如实说。
    expect(find.byKey(const Key('child-shortage-banner')), findsOneWidget);
    expect(find.text('已下单的件里，还有 1 种下层物料没下够'), findsOneWidget);

    await _check(tester, _productCheckbox('product-1'));
    await _submitMainTable(tester);
    expect(
      _writes().map((request) => request.path.split('/').last).toList(),
      ['issue-plans'],
      reason: '只下了顶层产品(父件)',
    );

    expect(find.byKey(const Key('child-shortage-dialog')), findsOneWidget);
    expect(find.text('下层物料还不够'), findsOneWidget);
    expect(find.text('刚下单 1000件'), findsOneWidget);
    for (final name in ['铜片', '弹簧', '自制底座', '底座原料']) {
      expect(
        find.descendant(
          of: find.byKey(const Key('child-shortage-dialog')),
          matching: find.text(name),
        ),
        findsOneWidget,
        reason: '$name 是刚下单的父件的下层, 还缺',
      );
    }
    expect(
      find.descendant(
        of: find.byKey(const Key('child-shortage-dialog')),
        matching: find.text('委外件的子料'),
      ),
      findsNothing,
      reason: '别的件(之前下的委外件)下面缺的料不在这次的弹窗里, 由提示条提醒',
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('child-shortage-dialog')),
        matching: find.text('已备齐的料'),
      ),
      findsNothing,
      reason: '不缺的料不点名',
    );

    await tester.tap(find.byKey(const Key('child-shortage-later')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('child-shortage-dialog')), findsNothing);
    expect(find.byKey(const Key('child-shortage-page')), findsNothing);
    // 稍后再说：提示条把新缺的一起算上(父件 4 种 + 委外件 1 种)。
    expect(find.text('已下单的件里，还有 5 种下层物料没下够'), findsOneWidget);
  });

  testWidgets('去补下单：数量按缺口填好、父先子后一键下完，回主表下单数量已锁成累计', (tester) async {
    await _pump(tester);
    await _check(tester, _productCheckbox('product-1'));
    await _submitMainTable(tester);
    await tester.tap(find.byKey(const Key('child-shortage-go')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('child-shortage-page')), findsOneWidget);
    expect(find.text('要下单 4 种'), findsOneWidget);
    for (final line in ['m-c1', 'm-c2', 'm-c3', 'm-g1']) {
      expect(_pageLine(line), findsOneWidget, reason: '$line 列在补料页');
    }
    expect(_pageLine('m-ok'), findsNothing, reason: '已备齐的料不列');
    expect(
      find.byKey(ValueKey('child-shortage-net-${_groupKey('m-c2')}')),
      findsOneWidget,
    );
    expect(find.text('还缺 500个'), findsOneWidget, reason: '弹簧有 500 现货, 只缺 500');
    expect(find.text('用在「自制底座」里'), findsOneWidget, reason: '孙层说清用在哪一件里');

    await _submitShortagePage(tester);
    final writes = _writes();
    expect(
      writes.map((request) => request.path.split('/').last).toList(),
      ['issue-plans', 'notify'],
      reason: '父先子后：自制子件先下达车间, 采购最后一次提交',
    );
    final issued = (writes.first.body!['lines'] as List).single as Map;
    expect(issued['materialLineId'], 'm-c3');
    expect(issued['qty'], 1000);
    expect(issued['departmentId'], 'ws-1', reason: '车间按货品学习默认带出');
    expect(_notifyQty(writes.last.body, 'm-c1'), 1000);
    expect(_notifyQty(writes.last.body, 'm-c2'), 500);
    expect(_notifyQty(writes.last.body, 'm-g1'), 1000);

    expect(find.byKey(const Key('child-shortage-done')), findsOneWidget);
    expect(find.text('下层物料都下够了'), findsOneWidget);
    await tester.tap(find.byKey(const Key('child-shortage-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('child-shortage-page')), findsNothing);
    // 回到主表：刚下的料「下单数量」格锁成累计已下单量, 提示条只剩委外件那 1 种。
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            widget.message?.startsWith('累计已下单 1000。') == true,
      ),
      findsWidgets,
    );
    expect(find.text('已下单的件里，还有 1 种下层物料没下够'), findsOneWidget);
    expect(
      find.byKey(const Key('child-shortage-dialog')),
      findsNothing,
      reason: '补料页里下的单不再弹一遍',
    );
  });

  testWidgets('追加父件后子件列成「追加」, 预填新缺口, 提交的是追加量', (tester) async {
    await _pump(tester, issuedRoot: true);
    expect(
      find.text('已下单的件里，还有 1 种下层物料没下够'),
      findsOneWidget,
      reason: '开关面板与它的下层都已下够, 只剩另一件产品的委外子料',
    );
    await tester.enterText(_appendQty('m-root'), '200');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    await _check(tester, _productCheckbox('product-1'));
    await _submitMainTable(tester);

    expect(find.byKey(const Key('child-shortage-dialog')), findsOneWidget);
    expect(find.text('刚追加 200件'), findsOneWidget);
    await tester.tap(find.byKey(const Key('child-shortage-go')));
    await tester.pumpAndSettle();
    expect(find.text('要追加 1 种'), findsOneWidget);
    expect(find.text('要下单 1 种'), findsNothing);
    expect(
      find.descendant(of: _pageLine('m-c1'), matching: find.text('追加')),
      findsOneWidget,
    );
    final field = tester.widget<TextField>(
      find.descendant(of: _pageLine('m-c1'), matching: find.byType(TextField)),
    );
    expect(field.controller!.text, '200', reason: '追加量预填 = 新缺口');

    await _submitShortagePage(tester);
    final notify = _writes().single;
    expect(notify.path, endsWith('/notify'));
    expect(_notifyQty(notify.body, 'm-c1'), 200);
    expect(find.byKey(const Key('child-shortage-done')), findsOneWidget);
  });

  testWidgets('只下采购件(没有下层)不弹窗', (tester) async {
    await _pump(tester);
    await _check(tester, _rowCheckbox('m-c1'));
    await _submitMainTable(tester);
    expect(_writes().single.path, endsWith('/notify'));
    expect(find.byKey(const Key('child-shortage-dialog')), findsNothing);
  });

  testWidgets('补料页：取消勾选的不提交；没定供应方式的不能勾并说原因', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        (data['flatMaterials'] as List).add(
          _material(line: 'm-c4', name: '未定方式件', confirmed: null, net: 300),
        );
        return data;
      },
    );
    await _check(tester, _productCheckbox('product-1'));
    await _submitMainTable(tester);
    await tester.tap(find.byKey(const Key('child-shortage-go')));
    await tester.pumpAndSettle();

    expect(find.text('先选供应方式 1 种'), findsOneWidget);
    final routeless = tester.widget<Checkbox>(
      find.byKey(ValueKey('child-shortage-check-${_groupKey('m-c4')}')),
    );
    expect(routeless.value, isFalse);
    expect(routeless.onChanged, isNull, reason: '没定供应方式的行不能下单');
    expect(
      find.byKey(ValueKey('child-shortage-blocked-${_groupKey('m-c4')}')),
      findsOneWidget,
    );

    tester
        .widget<Checkbox>(
          find.byKey(ValueKey('child-shortage-check-${_groupKey('m-c2')}')),
        )
        .onChanged!(false);
    await tester.pump();
    expect(find.text('已选 3 / 5 种'), findsOneWidget);

    await _submitShortagePage(tester);
    final notify = _writes().last;
    expect(_notifyQty(notify.body, 'm-c1'), 1000);
    expect(_notifyQty(notify.body, 'm-c2'), isNull, reason: '撤了勾的不下');
    expect(_notifyQty(notify.body, 'm-c4'), isNull);
    // 剩下没下的两行仍在页上, 等人处理。
    expect(_pageLine('m-c2'), findsOneWidget);
    expect(_pageLine('m-c4'), findsOneWidget);
    expect(_pageLine('m-c1'), findsNothing);
  });

  testWidgets('车间在催：提示条变红, 补料页挂「车间在催」, 下完立即核对办结', (tester) async {
    await _pump(
      tester,
      urges: [
        {
          'urgeId': 'urge-1',
          'segmentId': 'seg-1',
          'segmentCode': 'ZX-001',
          'productName': '委外件',
          'workshopName': '二车间',
          'lastUrgedByName': '李四',
          'lastUrgedAt': DateTime.now()
              .subtract(const Duration(minutes: 5))
              .toUtc()
              .toIso8601String(),
          'urgeCount': 2,
          'gapKindCount': 1,
          'gapSummary': '委外件的子料 600个',
          'shortMaterialLineIds': ['m-pc'],
        },
      ],
    );
    expect(
      find.byKey(const Key('child-shortage-banner-urgent')),
      findsOneWidget,
    );
    expect(find.text('车间在催：1 个任务等料开工'), findsOneWidget);
    expect(find.textContaining('二车间 李四 5 分钟前 催了 2 次'), findsOneWidget);

    await tester.tap(find.byKey(const Key('child-shortage-banner-go')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('child-shortage-page')), findsOneWidget);
    expect(
      find.descendant(of: _pageLine('m-pc'), matching: find.text('车间在催')),
      findsOneWidget,
    );
    expect(find.text('车间在催 1 种'), findsOneWidget);
    expect(find.text('已下单 1000个'), findsOneWidget, reason: '提示条入口按累计已下单说');

    await _submitShortagePage(tester);
    expect(_notifyQty(_writes().single.body, 'm-pc'), 600);
    expect(
      requests.where((r) => r.path.endsWith('/workshop-urges/reconcile')),
      isNotEmpty,
      reason: '下完立即核对, 不等后台 5 分钟',
    );
    expect(find.byKey(const Key('child-shortage-done')), findsOneWidget);
  });
}

// ------------------------------------------------------------------ fixture

Future<void> _pump(
  WidgetTester tester, {
  bool issuedRoot = false,
  List<Map<String, dynamic>> urges = const [],
  Map<String, dynamic> Function(Map<String, dynamic> data)? mutate,
}) async {
  requests.clear();
  await tester.pumpWidget(const SizedBox.shrink());
  tester.view.physicalSize = const Size(1800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  var data =
      jsonDecode(jsonEncode(_analysis(issuedRoot: issuedRoot)))
          as Map<String, dynamic>;
  if (mutate != null) data = mutate(data);
  var liveUrges = List<Map<String, dynamic>>.of(urges);

  Map<String, dynamic> bumped() {
    data = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
    final version = (data['version'] as int) + 1;
    data['version'] = version;
    data['fingerprint'] = '$version'.padLeft(64, 'b');
    return data;
  }

  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) async {
        requests.add((
          method: request.method,
          path: request.path,
          body: request.data is Map
              ? (request.data as Map).cast<String, dynamic>()
              : null,
        ));
        Object result = <Object>[];
        final path = request.path;
        if (path == '/master/warehouses/dict') {
          result = [
            {'id': 'warehouse-1', 'name': '原料仓', 'code': '001'},
          ];
        } else if (path.endsWith('/default-workshops')) {
          result = [
            for (final goodsId in ['g-m-root', 'g-m-c3'])
              {
                'goodsId': goodsId,
                'departmentId': 'ws-1',
                'departmentName': '装配一车间',
                'responsibleEmployeeId': 'w-1',
                'responsibleEmployeeName': '张三',
              },
          ];
        } else if (path.endsWith('/workshop-urges') &&
            request.method == 'GET') {
          result = liveUrges;
        } else if (path.endsWith('/workshop-urges/reconcile')) {
          // 服务端核对：计划已下够的办结。
          liveUrges = [
            for (final urge in liveUrges)
              if ((urge['shortMaterialLineIds'] as List).any(
                (line) =>
                    _num(_line(data, line as String)['netShortageQty']) > 0,
              ))
                urge,
          ];
          result = {'resolved': urges.length - liveUrges.length};
        } else if (path.endsWith('/issue-plans/preview')) {
          result = data;
        } else if (path.endsWith('/issue-plans')) {
          _applyIssuePlans(data, request.data as Map<String, dynamic>);
          result = {
            'analysis': bumped(),
            'replayed': false,
            'plans': <Object>[],
          };
        } else if (path.endsWith('/notify')) {
          _applyNotify(data, request.data as Map<String, dynamic>);
          result = bumped();
        } else if (path == '/production/material-analyses/analysis-1') {
          result = data;
        } else if (path.endsWith('/transferable-in-summary')) {
          result = {'qtyByMaterialLineId': <String, Object>{}};
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
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        materialAnalysisWarehousePrefsProvider.overrideWith(
          _WarehousePrefs.new,
        ),
        currentPermissionsProvider.overrideWithValue(_permissions),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildLightTheme(),
        home: const ProductionMaterialAnalysisPage(
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

/// 顶层产品「开关面板」(自制) 1000 件：
/// - 铜片 m-c1(采购, 缺 1000)、弹簧 m-c2(采购, 有 500 现货, 缺 500)、
///   自制底座 m-c3(自制, 缺 1000) → 底座原料 m-g1(采购, 缺 1000)、已备齐的料 m-ok(不缺)；
/// - 另一件早就下过单的产品「插座底板」→ 委外件 m-p(我方供料单一子件, 已下单)
///   → 委外件的子料 m-pc(采购, 缺 600)。
/// [issuedRoot] = 父件与下层都已下够单(父件计划 1000 已排满, 铜片已订 1000)。
Map<String, dynamic> _analysis({required bool issuedRoot}) => {
  'analysisId': 'analysis-1',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse-1',
  'warehouseIds': ['warehouse-1'],
  'status': 'ACTIVE',
  'allowedActions': [
    'VIEW',
    'CONFIRM_ROUTES',
    'NOTIFY_SUPPLY',
    'GENERATE_PLAN',
    'OVER_SUPPLY',
  ],
  'products': [
    {
      'analysisLineId': 'product-1',
      'sourceType': 'SALES_ORDER',
      'goodsId': 'product-goods',
      'goodsCode': 'KG-1',
      'goodsName': '开关面板',
      'requestedQty': 1000,
      'remainingQty': issuedRoot ? 0 : 1000,
      'issuedPlanQty': issuedRoot ? 1000 : 0,
      'readyNowQty': 0,
      'canSchedule': !issuedRoot,
      'canIssueSurplus': true,
      'maxSchedulableQty': issuedRoot ? 0 : 1000,
      'unitName': '件',
      'rootMaterialLineId': 'm-root',
      if (issuedRoot) 'latestPlanId': 'plan-0',
    },
    // 另一件早就下过单的产品：它下面的委外件缺料, 与「开关面板」这次下单无关。
    {
      'analysisLineId': 'product-2',
      'sourceType': 'SALES_ORDER',
      'goodsId': 'product-goods-2',
      'goodsCode': 'KG-2',
      'goodsName': '插座底板',
      'requestedQty': 1000,
      'remainingQty': 0,
      'issuedPlanQty': 1000,
      'readyNowQty': 0,
      'canSchedule': false,
      'canIssueSurplus': true,
      'maxSchedulableQty': 0,
      'unitName': '个',
      'rootMaterialLineId': 'm-root2',
      'latestPlanId': 'plan-old',
    },
  ],
  'flatMaterials': [
    _material(
      line: 'm-root',
      name: '开关面板',
      confirmed: 'MAKE',
      net: issuedRoot ? 0 : 1000,
      nodeRole: 'ROOT_SUPPLY',
      level: 0,
      unit: '件',
    ),
    _material(
      line: 'm-c1',
      name: '铜片',
      confirmed: 'BUY',
      net: issuedRoot ? 0 : 1000,
      downstream: issuedRoot
          ? const [
              {
                'actionId': 'act-c1',
                'route': 'BUY',
                'status': 'CREATED',
                'documentNo': 'PR-1',
                'allocatedQty': 1000,
              },
            ]
          : const [],
    ),
    _material(
      line: 'm-c2',
      name: '弹簧',
      confirmed: 'BUY',
      net: issuedRoot ? 0 : 500,
      stock: 500,
    ),
    _material(
      line: 'm-c3',
      name: '自制底座',
      confirmed: 'MAKE',
      net: issuedRoot ? 0 : 1000,
    ),
    _material(
      line: 'm-g1',
      name: '底座原料',
      confirmed: 'BUY',
      net: issuedRoot ? 0 : 1000,
      level: 2,
      parentLine: 'm-c3',
    ),
    _material(
      line: 'm-ok',
      name: '已备齐的料',
      confirmed: 'BUY',
      net: 0,
      stock: 1000,
    ),
    _material(
      line: 'm-root2',
      name: '插座底板',
      confirmed: 'MAKE',
      net: 0,
      nodeRole: 'ROOT_SUPPLY',
      level: 0,
      product: 'product-2',
    ),
    _material(
      line: 'm-p',
      name: '委外件',
      product: 'product-2',
      confirmed: 'SUBCONTRACT',
      subcontractOutboundForm: 'COMPONENT_OUTBOUND',
      net: 0,
      stock: 0,
      downstream: const [
        {
          'actionId': 'act-p',
          'route': 'SUBCONTRACT',
          'status': 'CREATED',
          'documentNo': 'SC-1',
          'allocatedQty': 1000,
        },
      ],
    ),
    _material(
      line: 'm-pc',
      name: '委外件的子料',
      product: 'product-2',
      confirmed: 'BUY',
      net: 600,
      level: 2,
      parentLine: 'm-p',
    ),
  ],
  'supplyActions': [
    {
      'actionId': 'act-p',
      'route': 'SUBCONTRACT',
      'operationType': 'SUPPLY',
      'requestedQty': 1000,
      'publicSurplusQty': 0,
    },
    if (issuedRoot)
      {
        'actionId': 'act-c1',
        'route': 'BUY',
        'operationType': 'SUPPLY',
        'requestedQty': 1000,
        'publicSurplusQty': 0,
      },
  ],
};

Map<String, dynamic> _material({
  required String line,
  required String name,
  required String? confirmed,
  required double net,
  double stock = 0,
  String nodeRole = 'BOM_NODE',
  int level = 1,
  String? parentLine,
  String? subcontractOutboundForm,
  String unit = '个',
  String product = 'product-1',
  List<Map<String, dynamic>> downstream = const [],
}) => {
  'subcontractOutboundForm': ?subcontractOutboundForm,
  'materialLineId': line,
  'analysisLineId': product,
  'nodeRole': nodeRole,
  'nodeKey': 'n-$line',
  if (parentLine != null) 'parentNodeKey': 'n-$parentLine',
  'actionGroupKey': 'a-$line',
  'goodsId': 'g-$line',
  'goodsCode': 'M-$line',
  'goodsName': name,
  'unitName': unit,
  'unitId': 'unit-1',
  'level': level,
  'path': ['开关面板', name],
  'requiredQty': 1000,
  'sourceRequiredQty': 1000,
  'allocatedAvailableQty': stock,
  'availableQty': stock,
  'shortageQty': 1000 - stock,
  'demandSupplyGapQty': 1000 - stock,
  'inboundQty': 0,
  'additionalSupplyRecommendedQty': net,
  'netShortageQty': net,
  'sourceSuggestion': 'BUY',
  'sourceConfirmed': confirmed,
  'routeConfirmed': confirmed != null,
  'controlStage': 'START',
  'hardGate': true,
  'actionable': true,
  'downstreamReferences': downstream,
};

Map<String, dynamic> _line(Map<String, dynamic> data, String line) =>
    (data['flatMaterials'] as List).cast<Map<String, dynamic>>().firstWhere(
      (material) => material['materialLineId'] == line,
    );

double _num(Object? value) => (value as num?)?.toDouble() ?? 0;

/// 像服务端那样写回 notify：本行挂下游引用, 缺口扣掉。
void _applyNotify(Map<String, dynamic> data, Map<String, dynamic> body) {
  final route = body['target'] as String;
  for (final raw in (body['quantities'] as List? ?? const [])) {
    final quantity = raw as Map;
    final key = quantity['actionGroupKey'] as String;
    final line = key.substring(2);
    final material = _line(data, line);
    final qty = _num(quantity['qty']);
    final residual = _num(material['additionalSupplyRecommendedQty']);
    final demand = qty < residual ? qty : residual;
    final actionId = 'act-$line-${requests.length}';
    material['downstreamReferences'] = [
      ...(material['downstreamReferences'] as List? ?? const []),
      {
        'actionId': actionId,
        'route': route,
        'status': 'CREATED',
        'documentNo': 'REQ-$line',
        'allocatedQty': demand,
      },
    ];
    material['additionalSupplyRecommendedQty'] = residual - demand;
    material['netShortageQty'] = residual - demand;
    data['supplyActions'] = [
      ...(data['supplyActions'] as List? ?? const []),
      {
        'actionId': actionId,
        'route': route,
        'operationType': 'SUPPLY',
        'requestedQty': demand,
        'publicSurplusQty': qty - demand,
      },
    ];
  }
}

/// 像服务端那样写回 issue-plans：顶层行累加产品计划, 候选行建锚点并把该行缺口清零；
/// 顶层追加(纯公共备货)时下层铜片的需求跟着涨出新缺口。
void _applyIssuePlans(Map<String, dynamic> data, Map<String, dynamic> body) {
  final products = (data['products'] as List).cast<Map<String, dynamic>>();
  for (final raw in (body['lines'] as List? ?? const [])) {
    final line = raw as Map;
    final qty = _num(line['qty']);
    final analysisLineId = line['analysisLineId'] as String?;
    final materialLineId = line['materialLineId'] as String?;
    if (analysisLineId != null) {
      final product = products.firstWhere(
        (p) => p['analysisLineId'] == analysisLineId,
      );
      final remaining = _num(product['remainingQty']);
      final demand = qty < remaining ? qty : remaining;
      product['issuedPlanQty'] = _num(product['issuedPlanQty']) + qty;
      product['remainingQty'] = remaining - demand;
      product['canSchedule'] = remaining - demand > 0;
      product['latestPlanId'] = 'plan-${requests.length}';
      _line(data, 'm-root')['netShortageQty'] = 0;
      _line(data, 'm-root')['additionalSupplyRecommendedQty'] = 0;
      if (line['publicSurplusOnly'] == true) {
        final copper = _line(data, 'm-c1');
        copper['requiredQty'] = 1000 + qty;
        copper['additionalSupplyRecommendedQty'] = qty;
        copper['netShortageQty'] = qty;
      }
      continue;
    }
    final material = _line(data, materialLineId!);
    final anchorId = 'anchor-$materialLineId';
    material['planAnchorAnalysisLineId'] = anchorId;
    products.add({
      'analysisLineId': anchorId,
      'sourceType': 'MAKE_COMPONENT',
      'parentAnalysisLineId': 'product-1',
      'goodsId': material['goodsId'],
      'goodsCode': material['goodsCode'],
      'goodsName': material['goodsName'],
      'requestedQty': qty,
      'remainingQty': 0,
      'issuedPlanQty': qty,
      'canSchedule': false,
      'canIssueSurplus': true,
      'unitName': '个',
      'latestPlanId': 'plan-${requests.length}',
    });
    material['netShortageQty'] = 0;
    material['additionalSupplyRecommendedQty'] = 0;
  }
}

class _WarehousePrefs extends MaterialAnalysisWarehousePrefsNotifier {
  @override
  MaterialAnalysisWarehousePrefs build() =>
      const MaterialAnalysisWarehousePrefs();
  @override
  Future<void> syncNow() async {}
  @override
  void update(MaterialAnalysisWarehousePrefs next) => state = next;
}
