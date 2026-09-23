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
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';

void main() {
  for (final route in ['BUY', 'SUBCONTRACT']) {
    testWidgets(
      '$route issued selection keeps normal cell colors on the light tint',
      (tester) async {
        final analysis = _analysis();
        analysis['flatMaterials'] = [
          _material('first', '第一条已下达物料', route, 7, 4, 'IN_PROGRESS')
            ..['allocatedAvailableQty'] = 3,
          _material('second', '第二条已下达物料', route, 0, 10, 'DONE'),
        ];
        await _pump(
          tester,
          analysis: analysis,
          permissions: {
            Perm.productionMaterialAnalysisView,
            Perm.productionMaterialAnalysisNotify,
            Perm.productionMaterialAnalysisOverSupply,
          },
        );
        await _open(tester, route == 'BUY' ? 'buy' : 'subcontract');
        await _filter(tester, '已下达 (2)');
        // ADR-099：已下达行仍可勾选追加（有下达 + 超量权限时），勾选框照常渲染。
        expect(find.byType(Checkbox), findsWidgets);
        Finder row(String label) => find
            .ancestor(of: find.text(label), matching: find.byType(Row))
            .first;
        final first = row('第一条已下达物料');
        // 2026-09-15 已下达段对齐「下达车间」：缺口列退役，行的数量事实只剩
        // 需求量(10)与下达数量(4，无行动快照=分摊合计兜底)。
        final demand = find.descendant(of: first, matching: find.text('10'));
        // 2026-09-22 起桶表只读：已下的量在「下达数量」列里(4)，追加量进页填。
        final issued = find.descendant(of: first, matching: find.text('4'));
        final demandBefore = tester.widget<Text>(demand).style?.color;
        final issuedBefore = tester.widget<Text>(issued).style?.color;

        await tester.tap(find.text('第一条已下达物料'));
        await tester.pumpAndSettle();
        // 2026-09-13 全站表格选中口径：选中行淡绿底 + 常态字色——语义色
        // （缺口红/绿、说明灰）在选中前后保持一致，不再翻白。
        final selectedTexts = find.descendant(
          of: first,
          matching: find.byType(Text),
        );
        expect(selectedTexts.evaluate().length, greaterThan(5));
        for (final element in selectedTexts.evaluate()) {
          final text = element.widget as Text;
          expect(
            text.style?.color ?? DefaultTextStyle.of(element).style.color,
            isNot(Colors.white),
            reason:
                'Selected $route cell ${text.data} must stay normal-colored',
          );
        }
        expect(tester.widget<Text>(demand).style?.color, demandBefore);
        expect(tester.widget<Text>(issued).style?.color, issuedBefore);

        await tester.tap(find.text('第二条已下达物料'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(demand).style?.color, demandBefore);
        expect(tester.widget<Text>(issued).style?.color, issuedBefore);
        for (final element
            in find
                .descendant(of: row('第二条已下达物料'), matching: find.byType(Text))
                .evaluate()) {
          final text = element.widget as Text;
          expect(
            text.style?.color ?? DefaultTextStyle.of(element).style.color,
            isNot(Colors.white),
            reason:
                'The newly selected row must also keep normal colors '
                '(text: ${text.data})',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$route issued segment retires shortage column and shows real issued qty',
      (tester) async {
        final analysis = _analysis();
        final material = _material(
          'supply',
          '待到齐物料',
          route,
          10,
          4,
          'IN_PROGRESS',
        )..['remainingDemandSupplyGapQty'] = 6;
        analysis['flatMaterials'] = [material];
        await _pump(tester, analysis: analysis);
        await _open(tester, route == 'BUY' ? 'buy' : 'subcontract');
        await _filter(tester, '已下达 (1)');

        // 2026-09-15 用户口径（已下达段对齐「下达车间」）：缺口/仓库余量/BOM
        // 路径/订单总量四列从已下达段退役；「下达数量」直接显示真实已下达量
        //（本夹具无行动快照，回落分摊合计 4）。物理缺口仍是服务端口径，只是
        // 不再在这段回看——被需求冲抵的 6 同样不该出现。
        expect(find.byKey(const Key('bucket-shortage-qty-cell')), findsNothing);
        expect(find.text('待到齐物料'), findsOneWidget);
        expect(find.text('4'), findsOneWidget);
        expect(find.text('6'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('$route issued segment drops pre-issue ledger columns', (
      tester,
    ) async {
      final analysis = _analysis();
      analysis['flatMaterials'] = [
        _material('supply', '分批合格到货物料', route, 7, 15, 'IN_PROGRESS')
          ..['exactPeggedQty'] = 3
          ..['allocatedAvailableQty'] = 3
          ..['remainingDemandSupplyGapQty'] = 0,
      ];
      await _pump(tester, analysis: analysis);
      await _open(tester, route == 'BUY' ? 'buy' : 'subcontract');
      await _filter(tester, '已下达 (1)');
      // 已下达段不再回看下单前的库存账：缺口列整个不出现，真实下达量 15 直接
      // 显示在「下达数量」；被公共超量订单冲抵后的 6/已备 3 都不该露头。
      expect(find.byKey(const Key('bucket-shortage-qty-cell')), findsNothing);
      expect(find.text('15'), findsOneWidget);
      expect(find.text('7'), findsNothing);
      expect(find.text('3'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('preparation has three route entries and retains issued supply', (
    tester,
  ) async {
    final requests = await _pump(tester);
    for (final route in ['buy', 'subcontract', 'workshop']) {
      expect(find.byKey(Key('material-analysis-entry-$route')), findsOneWidget);
    }
    for (final retired in ['ready', 'waiting', 'transferred', 'make']) {
      expect(find.byKey(Key('material-analysis-entry-$retired')), findsNothing);
    }
    await _open(tester, 'buy');
    expect(find.text('部分采购物料'), findsOneWidget);
    expect(find.text('已完成采购物料'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);

    await _filter(tester, '已下达 (2)');
    expect(find.text('部分采购物料'), findsOneWidget);
    expect(find.text('已完成采购物料'), findsOneWidget);
    expect(
      find.byKey(const Key('material-analysis-bucket-action-buy')),
      findsNothing,
    );
    expect(requests.where((request) => request.method != 'GET'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('issued segment lets a supply operator append extra quantity', (
    tester,
  ) async {
    // 追加量属公共备货：要有超量下达权限才给勾（没有的账号已下达行照旧只读）。
    final requests = await _pump(
      tester,
      permissions: {
        Perm.productionMaterialAnalysisView,
        Perm.productionMaterialAnalysisNotify,
        Perm.productionMaterialAnalysisOverSupply,
      },
    );
    await _open(tester, 'buy');
    final header = find.byWidgetPredicate(
      (widget) => widget is Checkbox && widget.tristate,
    );
    await tester.tap(header);
    await tester.pumpAndSettle();
    // 2026-09-22 起外层桶表只读：没有任何输入框，数量在「核对并下单」页里填。
    expect(find.byType(TextField), findsNothing);
    expect(
      find.byKey(const Key('material-analysis-bucket-action-buy')),
      findsOneWidget,
    );
    await _filter(tester, '已下达 (2)');
    // ADR-099 父层级追加：已下达行仍可勾选；桶表只显示已下达量，追加量进页填；
    // 按钮改叫「追加采购」，省略号 = 还要过一页。
    expect(find.byType(Checkbox), findsWidgets);
    expect(find.text('追加采购(0)…'), findsOneWidget);
    expect(find.text('下达数量'), findsOneWidget);
    expect(requests.where((request) => request.method != 'GET'), isEmpty);
    await _tapRowCheckbox(tester, '已完成采购物料');
    await tester.tap(find.text('追加采购(1)…'));
    await tester.pumpAndSettle();
    // 追加量默认就写 0(0 = 本次不追加)，在页里改成 5。
    final append = find.byKey(
      const ValueKey('material-analysis-child-cascade-qty-material-complete'),
    );
    expect(tester.widget<TextField>(append).controller!.text, '0');
    await tester.enterText(append, '5');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('supply-submit-confirm')));
    await tester.pumpAndSettle();
    // 追加量原样送 notify（服务端按超量分账为公共备货：未处理的申请就地改大、
    // 已处理的另立新单）。
    final notify = requests
        .where((request) => request.path.endsWith('/notify'))
        .toList();
    expect(notify, hasLength(1));
    final body = notify.single.data as Map<String, dynamic>;
    expect(body['target'], 'BUY');
    expect(body['quantities'], [
      {
        'actionGroupKey': 'action-complete',
        'qty': 5.0,
        'safetyReplenishmentQty': 0.0,
      },
    ]);
  });

  testWidgets(
    'workshop can select waiting materials but not server-blocked plans',
    (tester) async {
      final requests = await _pump(
        tester,
        permissions: {
          Perm.productionMaterialAnalysisView,
          Perm.productionMaterialAnalysisGenerate,
        },
      );
      await _open(tester, 'workshop');
      expect(find.text('缺料但可排产产品'), findsOneWidget);
      expect(find.textContaining('结构待修复产品'), findsOneWidget);
      expect(find.textContaining('历史完成产品'), findsNothing);
      final header = find.byWidgetPredicate(
        (widget) => widget is Checkbox && widget.tristate,
      );
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'创建生产计划.*\(1\)')), findsOneWidget);
      // 2026-09-22 起外层桶表只读：数量 / 车间 / 负责人都在进页之后填。
      expect(find.byType(TextField), findsNothing);

      await _filter(tester, '需处理 (1)');
      expect(find.textContaining('结构待修复产品'), findsOneWidget);
      expect(find.text('BOM 结构待修复'), findsWidgets);
      expect(find.byType(Checkbox), findsNothing);
      await _filter(tester, '已下达 (1)');
      expect(find.textContaining('历史完成产品'), findsOneWidget);
      expect(find.text('已完工'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      expect(requests.where((request) => request.method != 'GET'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

/// 按行内文本定位整行（行首勾选格在冻结包裹层里）并点它的勾选框。
Future<void> _tapRowCheckbox(WidgetTester tester, String text) async {
  final frozen = find.ancestor(
    of: find.text(text).first,
    matching: find.byType(UtenFrozenLeadingColumn),
  );
  final row = frozen.evaluate().isNotEmpty
      ? frozen.first
      : find
            .ancestor(of: find.text(text).first, matching: find.byType(Row))
            .first;
  final checkbox = find
      .descendant(of: row, matching: find.byType(Checkbox))
      .first;
  await tester.ensureVisible(checkbox);
  await tester.pumpAndSettle();
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, String route) async {
  final entry = find.byKey(Key('material-analysis-entry-$route'));
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

Future<void> _filter(WidgetTester tester, String label) async {
  final filter = find.descendant(
    of: find.byKey(const Key('material-analysis-task-state')),
    matching: find.text(label),
  );
  await tester.ensureVisible(filter);
  await tester.tap(filter);
  await tester.pumpAndSettle();
}

Future<List<RequestOptions>> _pump(
  WidgetTester tester, {
  Set<String> permissions = const {Perm.productionMaterialAnalysisView},
  Map<String, dynamic>? analysis,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final requests = <RequestOptions>[];
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        final data = switch (request.path) {
          '/master/warehouses/dict' => [
            {'id': 'warehouse-1', 'name': '主仓'},
          ],
          '/production/material-analyses/analysis-1' => analysis ?? _analysis(),
          '/production/material-analyses/analysis-1/notify' =>
            analysis ?? _analysis(),
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
        currentPermissionsProvider.overrideWithValue(permissions),
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
  return requests;
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
  'allowedActions': [
    'VIEW',
    'NOTIFY_SUPPLY',
    'OVER_SUPPLY',
    'PLAN_PREVIEW',
    'GENERATE_PLAN',
  ],
  'products': [
    _product('ready', '缺料但可排产产品', canSchedule: true),
    _product('blocked', '结构待修复产品', canSchedule: false),
    _product('complete', '历史完成产品', canSchedule: false)
      ..['remainingQty'] = 0
      ..['submittedQty'] = 10
      ..['planExecutionStatus'] = 'COMPLETED'
      ..['latestPlanId'] = 'plan-completed',
  ],
  'flatMaterials': [
    _material('partial', '部分采购物料', 'BUY', 10, 4, 'IN_PROGRESS'),
    _material('complete', '已完成采购物料', 'BUY', 0, 10, 'DONE'),
    _material('subcontract', '待委外物料', 'SUBCONTRACT', 10, 0, null),
  ],
  'warehouses': [
    {'warehouseId': 'warehouse-1', 'warehouseName': '主仓'},
  ],
};

Map<String, dynamic> _product(
  String id,
  String name, {
  required bool canSchedule,
}) => {
  'analysisLineId': id,
  'sourceType': 'STOCK',
  'goodsId': 'goods-$id',
  'goodsCode': 'P-$id',
  'goodsName': name,
  'requestedQty': 10,
  'remainingQty': 10,
  'readyNowQty': 0,
  'canSchedule': canSchedule,
  'maxSchedulableQty': canSchedule ? 10 : 0,
  'scheduleBlockedReason': canSchedule ? null : 'BOM 结构待修复',
};

Map<String, dynamic> _material(
  String id,
  String name,
  String route,
  double gap,
  double issued,
  String? status,
) => {
  'materialLineId': 'material-$id',
  'analysisLineId': 'ready',
  'nodeKey': 'node-$id',
  'actionGroupKey': 'action-$id',
  'goodsId': 'goods-$id',
  'goodsCode': 'M-$id',
  'goodsName': name,
  'unitName': '个',
  'level': 1,
  'path': ['缺料但可排产产品', name],
  'requiredQty': 10,
  'shortageQty': gap,
  'demandSupplyGapQty': gap,
  // 服务端「还可下达」= max(0, 缺口 − 有效在途覆盖)：未撤销/未完成的下游
  // 引用按分摊量扣掉(ADR-099 起界面不再自己估这个数)。
  'additionalSupplyRecommendedQty':
      status == null || status == 'DONE' || status == 'CANCELLED'
      ? gap
      : (gap - issued > 0 ? gap - issued : 0.0),
  'sourceSuggestion': route,
  'sourceConfirmed': route,
  'routeConfirmed': true,
  'actionable': true,
  'downstreamReferences': [
    if (status != null)
      {
        'actionId': 'issued-$id',
        'target': route,
        'status': status,
        'allocatedQty': issued,
        'documentNo': 'PO-$id',
      },
  ],
};
