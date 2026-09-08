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
  for (final route in ['BUY', 'SUBCONTRACT']) {
    testWidgets(
      '$route issued selection uses white text in every light-mode cell',
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
          },
        );
        await _open(tester, route == 'BUY' ? 'buy' : 'subcontract');
        await _filter(tester, '已下达 (2)');
        expect(find.byType(Checkbox), findsNothing);
        Finder row(String label) => find
            .ancestor(of: find.text(label), matching: find.byType(Row))
            .first;
        final first = row('第一条已下达物料');
        final shortage = find.descendant(of: first, matching: find.text('7'));
        final issued = find.descendant(of: first, matching: find.text('4'));
        final shortageBefore = tester.widget<Text>(shortage).style?.color;
        final issuedBefore = tester.widget<Text>(issued).style?.color;
        expect(shortageBefore, isNot(Colors.white));
        expect(issuedBefore, isNot(Colors.white));

        await tester.tap(find.text('第一条已下达物料'));
        await tester.pumpAndSettle();
        final selectedTexts = find.descendant(
          of: first,
          matching: find.byType(Text),
        );
        expect(selectedTexts.evaluate().length, greaterThan(5));
        for (final element in selectedTexts.evaluate()) {
          final text = element.widget as Text;
          expect(
            text.style?.color ?? DefaultTextStyle.of(element).style.color,
            Colors.white,
            reason: 'Selected $route cell ${text.data} must remain readable',
          );
        }

        await tester.tap(find.text('第二条已下达物料'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(shortage).style?.color, shortageBefore);
        expect(tester.widget<Text>(issued).style?.color, issuedBefore);
        for (final element
            in find
                .descendant(of: row('第二条已下达物料'), matching: find.byType(Text))
                .evaluate()) {
          final text = element.widget as Text;
          expect(
            text.style?.color ?? DefaultTextStyle.of(element).style.color,
            Colors.white,
            reason: 'The newly selected row must also use white text',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$route issue preserves physical shortage until qualified receipt',
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

        Finder shortageCell(String qty) => find.descendant(
          of: find.byWidgetPredicate(
            (widget) =>
                widget is Tooltip &&
                (widget.message?.startsWith('本批需求扣除') ?? false),
          ),
          matching: find.text(qty),
        );
        expect(shortageCell('10'), findsOneWidget);
        expect(shortageCell('4'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('$route physical shortage excludes public surplus orders', (
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
      final physicalShortage = find.descendant(
        of: find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              (widget.message?.startsWith('本批需求扣除') ?? false),
        ),
        matching: find.text('7'),
      );
      expect(physicalShortage, findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('6'), findsNothing);
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

  testWidgets('issued state is read only even for a supply operator', (
    tester,
  ) async {
    final requests = await _pump(
      tester,
      permissions: {
        Perm.productionMaterialAnalysisView,
        Perm.productionMaterialAnalysisNotify,
      },
    );
    await _open(tester, 'buy');
    final header = find.byWidgetPredicate(
      (widget) => widget is Checkbox && widget.tristate,
    );
    await tester.tap(header);
    await tester.pumpAndSettle();
    final selectedQuantity = tester.widget<TextField>(
      find.byKey(
        const ValueKey('material-analysis-bucket-submit-qty-action-partial'),
      ),
    );
    expect(selectedQuantity.style?.color, Colors.white);
    expect(selectedQuantity.decoration?.suffixStyle?.color, Colors.white);
    expect(selectedQuantity.decoration?.hintStyle?.color, Colors.white);
    expect(
      selectedQuantity.decoration?.fillColor,
      Colors.white.withValues(alpha: 0.12),
    );
    expect(
      find.byKey(const Key('material-analysis-bucket-action-buy')),
      findsOneWidget,
    );
    await _filter(tester, '已下达 (2)');
    expect(find.byType(Checkbox), findsNothing);
    expect(
      find.byKey(const Key('material-analysis-bucket-action-buy')),
      findsNothing,
    );
    expect(requests.where((request) => request.method != 'GET'), isEmpty);
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
      expect(find.text('创建生产计划(1)'), findsOneWidget);
      final fields = tester.widgetList<TextField>(find.byType(TextField));
      expect(fields, isNotEmpty);

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
  'allowedActions': ['VIEW', 'NOTIFY_SUPPLY', 'PLAN_PREVIEW', 'GENERATE_PLAN'],
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
