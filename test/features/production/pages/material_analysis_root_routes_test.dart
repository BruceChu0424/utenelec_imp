import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
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
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets('pending finance blocks only its own product route selections', (
    tester,
  ) async {
    const reason = '销售订单等待财务确认，已有任务进度照常更新，暂不能新增安排';
    final data = _analysis(routes: ['BUY', 'BUY'], withChildren: false);
    data['planningBlockedReasons'] = {'p1': reason};
    final parsed = ProductionMaterialAnalysisView.fromJson(data);
    expect(parsed.planningBlockedReason('p1'), reason);
    expect(parsed.planningBlockedReason('p2'), isNull);
    final harness = await _pump(tester, data);
    expect(find.text(reason), findsWidgets);
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('material-analysis-material-table-region')),
        matching: find.byWidgetPredicate((w) => w is Checkbox && w.tristate),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('确认路线(1)'), findsOneWidget);
    await _confirm(tester);
    expect(harness.writes, hasLength(1));
    expect(
      _decisions(harness.writes.single).single['actionGroupKey'],
      'root-action-2',
    );
    expect(tester.takeException(), isNull);
  });

  for (final explicitRole in [true, false]) {
    testWidgets(
      'issued root with retained material demand has no duplicate pending task (role $explicitRole)',
      (tester) async {
        final data =
            jsonDecode(
                  jsonEncode(
                    _analysis(
                      routes: ['MAKE'],
                      confirmed: true,
                      withChildren: false,
                    ),
                  ),
                )
                as Map<String, dynamic>;
        final product =
            (data['products'] as List).single as Map<String, dynamic>;
        product.addAll({
          'approvedQty': 10,
          'remainingQty': 0,
          'canSchedule': false,
          'maxSchedulableQty': 0,
          'planExecutionStatus': 'WAITING',
          'latestPlanId': 'issued-root-plan',
          'planExecutionPlannedQty': 10,
        });
        final root =
            (data['flatMaterials'] as List).single as Map<String, dynamic>;
        if (!explicitRole) root.remove('nodeRole');
        await _pump(tester, data);
        await _openBucket(tester, 'workshop');
        expect(find.text('等待下达车间 (0)'), findsOneWidget);
        expect(find.text('已下达 (1)'), findsOneWidget);
        await tester.tap(find.text('已下达 (1)'));
        await tester.pumpAndSettle();
        expect(find.text('车间已收到 · 等待物料'), findsOneWidget);
        expect(find.text('根产品 1(P-1)'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'seven issued plans with five direct MAKE anchors stay zero pending after refresh',
    (tester) async {
      final data = _issuedPlanAnchors();
      final harness = await _pump(tester, data, generate: true, refresh: true);
      await _openBucket(tester, 'workshop');
      expect(find.text('等待下达车间 (0)'), findsOneWidget);
      expect(find.text('已下达 (7)'), findsOneWidget);
      await tester.tap(find.text('已下达 (7)'));
      await tester.pumpAndSettle();
      expect(find.text('物料齐套 · 可开工'), findsNWidgets(3));
      expect(find.text('车间已收到 · 等待物料'), findsNWidgets(4));
      expect(find.text('创建生产计划(1)'), findsNothing);
      await _closeBucket(tester);
      final refreshes = harness.requests
          .where((request) => request.path.endsWith('/preview'))
          .length;
      await tester.tap(find.byTooltip('按最新库存刷新分析'));
      await tester.pumpAndSettle();
      expect(
        harness.requests.where((request) => request.path.endsWith('/preview')),
        hasLength(refreshes + 1),
      );
      await _openBucket(tester, 'workshop');
      expect(find.text('等待下达车间 (0)'), findsOneWidget);
      expect(find.text('已下达 (7)'), findsOneWidget);
      expect(
        harness.requests.where(
          (request) =>
              request.path.endsWith('/issue-plans') ||
              request.path.endsWith('/notify'),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same goods on two anchored paths schedule only the existing child remainder',
    (tester) async {
      final data = _issuedPlanAnchors(partialSecondPath: true);
      final harness = await _pump(tester, data, generate: true);
      await _openBucket(tester, 'workshop');
      expect(find.text('等待下达车间 (1)'), findsOneWidget);
      expect(find.text('已下达 (7)'), findsOneWidget);
      expect(find.text('自制组件 1'), findsNothing);
      expect(find.text('自制组件 2'), findsOneWidget);
      expect(find.text('来源自制件 2'), findsNothing);
      final row = find
          .ancestor(of: find.text('自制组件 2'), matching: find.byType(Row))
          .first;
      final quantity = find.descendant(
        of: row,
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(quantity).controller!.text, '4000');
      await tester.tap(
        find.descendant(of: row, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      expect(find.text('创建生产计划(1)'), findsOneWidget);
      await tester.tap(find.text('已下达 (7)'));
      await tester.pumpAndSettle();
      expect(find.text('创建生产计划(1)'), findsNothing);
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .where((checkbox) => checkbox.onChanged != null),
        isEmpty,
      );
      await tester.tap(find.text('等待下达车间 (1)'));
      await tester.pumpAndSettle();
      final pendingRow = _frozenRowOf('自制组件 2');
      final check = find.descendant(
        of: pendingRow,
        matching: find.byType(Checkbox),
      );
      if (tester.widget<Checkbox>(check).value != true) {
        await tester.tap(check);
        await tester.pumpAndSettle();
      }
      await tester.tap(
        find.byKey(const Key('material-analysis-bucket-action-ready')),
      );
      await tester.pumpAndSettle();
      final issue = harness.requests.singleWhere(
        (request) => request.path.endsWith('/issue-plans'),
      );
      final lines = ((issue.data as Map<String, dynamic>)['lines'] as List)
          .cast<Map<String, dynamic>>();
      expect(lines, hasLength(1));
      expect(lines.single['analysisLineId'], 'plan-anchor-2');
      expect(lines.single['materialLineId'], isNull);
      expect(lines.single['qty'], 4000);
      expect((data['products'] as List), hasLength(7));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'issued legacy flow without its child identity remains read only until progress syncs',
    (tester) async {
      final data = _issuedPlanAnchors();
      final first = (data['flatMaterials'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((row) => row['materialLineId'] == 'child-1-1');
      first.remove('planAnchorAnalysisLineId');
      first['flowStage'] = 'MAKE_WAITING_DRAW';
      (data['products'] as List).removeWhere(
        (row) => (row as Map)['analysisLineId'] == 'plan-anchor-1',
      );
      final harness = await _pump(tester, data, generate: true);
      expect(find.text('已下达，计划进度待同步'), findsWidgets);
      await _openBucket(tester, 'workshop');
      expect(find.text('等待下达车间 (0)'), findsOneWidget);
      expect(find.text('已下达 (6)'), findsOneWidget);
      expect(
        harness.requests.where(
          (request) => request.path.endsWith('/issue-plans'),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '501 mixed BOM routes confirm deepest first before a purchased root removes them',
    (tester) async {
      final data = _analysis(routes: ['BUY'], childrenPerProduct: 501);
      final materials = (data['flatMaterials'] as List)
          .cast<Map<String, dynamic>>();
      final root = materials.singleWhere(
        (row) => row['nodeRole'] == 'ROOT_SUPPLY',
      );
      root['actionGroupKey'] = '000-root-action';
      final expectedRoutes = <String, String>{};
      final depths = <String, int>{};
      for (var index = 1; index < materials.length; index++) {
        final row = materials[index];
        final route = ['BUY', 'MAKE', 'SUBCONTRACT'][(index - 1) % 3];
        final depth = index <= 250 ? 1 : 2;
        row['sourceSuggestion'] = route;
        row['level'] = depth;
        row['parentNodeKey'] = depth == 1
            ? null
            : 'child-node-1-${((index - 251) % 250) + 1}';
        expectedRoutes[row['actionGroupKey'] as String] = route;
        depths[row['actionGroupKey'] as String] = depth;
      }
      final harness = await _pump(
        tester,
        data,
        removeBomAfterExternalRootConfirmation: true,
      );
      // 「全选筛选结果」已下线：跨页全选改为逐页勾选表头复选框（100/页）。
      for (var page = 1; page <= 6; page++) {
        await tester.tap(
          find.descendant(
            of: find.byKey(
              const Key('material-analysis-material-table-region'),
            ),
            matching: find.byWidgetPredicate(
              (w) => w is Checkbox && w.tristate,
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (page < 6) {
          await tester.tap(find.text('下一页'));
          await tester.pumpAndSettle();
        }
      }
      expect(find.text('确认路线(502)'), findsOneWidget);
      await _confirm(tester);
      expect(harness.writes, hasLength(2));
      expect(harness.failedRouteResolutions, 0);
      final first = _decisions(harness.writes.first);
      final last = _decisions(harness.writes.last);
      expect(first, hasLength(500));
      expect(
        first.any((row) => row['actionGroupKey'] == '000-root-action'),
        isFalse,
      );
      expect(last, hasLength(2));
      expect(last.last, {'actionGroupKey': '000-root-action', 'route': 'BUY'});
      expect((harness.writes.last.data as Map<String, dynamic>)['version'], 4);
      expect(
        (harness.writes.last.data as Map<String, dynamic>)['fingerprint'],
        'b' * 64,
      );
      final componentDecisions = [...first, ...last.take(1)];
      expect(componentDecisions, hasLength(501));
      for (final decision in componentDecisions) {
        expect(decision['route'], expectedRoutes[decision['actionGroupKey']]);
      }
      final actualDepths = componentDecisions
          .map((row) => depths[row['actionGroupKey']]!)
          .toList();
      expect(
        actualDepths,
        [...actualDepths]..sort((left, right) => right.compareTo(left)),
      );
      expect(harness.routesBeforeRoot.single, expectedRoutes);
      expect(harness.confirmedRoutes, {
        ...expectedRoutes,
        '000-root-action': 'BUY',
      });
      expect(harness.data['flatMaterials'], hasLength(1));
      expect(find.text('确认路线(0)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'root shares one product row and confirms only its own actual route',
    (tester) async {
      final harness = await _pump(
        tester,
        _analysis(routes: ['SUBCONTRACT', 'BUY', 'MAKE']),
      );
      for (var index = 1; index <= 3; index++) {
        expect(_root(index), findsOneWidget);
        expect(
          find.byKey(ValueKey('material-table-row-root-$index')),
          findsNothing,
        );
        expect(
          find.descendant(of: _root(index), matching: _route(index)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: _root(index), matching: find.byType(Checkbox)),
          findsOneWidget,
        );
      }
      await _selectRoot(tester, 1);
      expect(find.text('确认路线(1)'), findsOneWidget);
      await _confirm(tester);
      expect(_decisions(harness.writes.single), [
        {'actionGroupKey': 'root-action-1', 'route': 'SUBCONTRACT'},
      ]);
      expect(
        (harness.data['flatMaterials'] as List)
            .cast<Map<String, dynamic>>()
            .where((row) => row['nodeRole'] != 'ROOT_SUPPLY')
            .every((row) => row['routeConfirmed'] == false),
        isTrue,
      );
      await _selectRoot(tester, 2);
      await _selectRoot(tester, 3);
      await _confirm(tester);
      expect(_decisions(harness.writes.last), [
        {'actionGroupKey': 'root-action-2', 'route': 'BUY'},
        {'actionGroupKey': 'root-action-3', 'route': 'MAKE'},
      ]);
      expect(
        harness.requests.where((request) => request.path.endsWith('/notify')),
        isEmpty,
      );
    },
  );

  testWidgets('issued root MAKE retains batch demand and expected output', (
    tester,
  ) async {
    final data = _analysis(
      routes: ['MAKE'],
      confirmed: true,
      withChildren: false,
    );
    final product = (data['products'] as List).first as Map<String, dynamic>;
    product['remainingQty'] = 0;
    product['approvedQty'] = 10;
    product['planExecutionStatus'] = 'WAITING';
    product['latestPlanId'] = 'issued-root-plan';
    final material =
        (data['flatMaterials'] as List).first as Map<String, dynamic>;
    material['inboundQty'] = 10;
    await _pump(tester, data);
    expect(
      find.descendant(
        of: _root(1),
        matching: find.textContaining(RegExp('^10.*已锚定')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _root(1), matching: find.text('10')),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'confirmed root MAKE waits for materials and generates the original product plan without a child',
    (tester) async {
      final data = _analysis(
        routes: ['MAKE'],
        confirmed: true,
        withChildren: false,
        unitRate: 20,
      );
      final harness = await _pump(tester, data, generate: true);
      final root = _root(1);
      expect(
        find.descendant(of: root, matching: find.text('200')),
        findsWidgets,
      );
      expect(
        find.descendant(of: root, matching: find.textContaining('件')),
        findsWidgets,
      );
      await _openBucket(tester, 'workshop');
      expect(find.text('根产品 1'), findsOneWidget);
      // 2026-09-05 顶层与子层同构：顶层行的类型也显示「自制候选」。
      expect(find.text('自制候选'), findsWidgets);
      expect(
        find.byKey(const Key('material-analysis-bucket-create-tasks')),
        findsNothing,
      );
      final productRow = find
          .ancestor(of: find.text('根产品 1'), matching: find.byType(Row))
          .first;
      final quantity = find.descendant(
        of: productRow,
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(quantity).controller!.text, '10');
      // 2026-09-06 统一流程词表：未下达的自制任务显示第一步「等待下达车间」，
      // 不区分下层齐套（齐套与否由计划审批后的执行段 WAITING/READY 自动判断）。
      expect(find.text('等待下达车间'), findsWidgets);
      await tester.tap(
        find.descendant(of: productRow, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      expect(find.text('创建生产计划(1)'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('material-analysis-bucket-action-ready')),
      );
      await tester.pumpAndSettle();
      final issueRequest = harness.requests.singleWhere(
        (request) => request.path.endsWith('/issue-plans'),
      );
      expect((issueRequest.data as Map<String, dynamic>)['lines'], [
        {
          'analysisLineId': 'p1',
          'qty': 10.0,
          'departmentId': 'workshop',
          'workshopName': '装配车间',
          'workerId': 'worker',
        },
      ]);
      expect((issueRequest.data as Map<String, dynamic>)['approveNow'], isTrue);
      expect(
        harness.requests.where((request) => request.path.endsWith('/notify')),
        isEmpty,
      );
      expect((harness.data['products'] as List), hasLength(1));
    },
  );

  testWidgets(
    'an unconfirmed root stays out of the workshop bucket until its route is confirmed',
    (tester) async {
      // 2026-09-05 顶层与子层自制同构：顶层路线未确认时不进车间桶（与未确认
      // 的子层候选同口径，只留在主表红色「路线待确认」）——车间桶入口计数为
      // 0 且灰显不可点；确认自制后才进入车间桶，与子层共用下层齐套词汇。
      final harness = await _pump(
        tester,
        _analysis(routes: ['MAKE'], withChildren: false),
        generate: true,
      );
      expect(find.text('路线待确认'), findsWidgets);
      final workshopEntry = find.byKey(
        const Key('material-analysis-entry-workshop'),
      );
      expect(workshopEntry, findsOneWidget);
      expect(
        find.descendant(of: workshopEntry, matching: find.text('0')),
        findsOneWidget,
      );
      expect(tester.widget<InkWell>(workshopEntry).onTap, isNull);
      // 确认自制后顶层进入车间桶、共用下层齐套词汇的契约由下方
      // 'confirmed root MAKE waits for materials...' 用例锁定。
      expect(
        harness.requests.where((request) => request.path.endsWith('/notify')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'root BUY and SUBCONTRACT appear in their route tasks and not pending workshop plans',
    (tester) async {
      final harness = await _pump(
        tester,
        _analysis(
          routes: ['BUY', 'SUBCONTRACT', 'MAKE'],
          confirmed: true,
          withChildren: false,
        ),
        generate: true,
      );
      await _openBucket(tester, 'buy');
      expect(find.text('根产品 1'), findsWidgets);
      expect(
        find.byKey(const ValueKey('row:NODE|root-action-1|root-1')),
        findsOneWidget,
      );
      expect(find.text('根产品 2'), findsNothing);
      await _closeBucket(tester);
      await _openBucket(tester, 'subcontract');
      expect(find.text('根产品 2'), findsWidgets);
      expect(
        find.byKey(const ValueKey('row:NODE|root-action-2|root-2')),
        findsOneWidget,
      );
      expect(find.text('根产品 1'), findsNothing);
      await _closeBucket(tester);
      await _openBucket(tester, 'workshop');
      expect(find.text('根产品 3'), findsOneWidget);
      expect(find.text('根产品 1'), findsNothing);
      expect(find.text('根产品 2'), findsNothing);
      expect(
        harness.requests.where((request) => request.method != 'GET'),
        isEmpty,
      );
    },
  );

  testWidgets(
    'a root without a BOM still exposes a real selectable supply route',
    (tester) async {
      final harness = await _pump(
        tester,
        _analysis(routes: [null], withChildren: false),
      );
      expect(_root(1), findsOneWidget);
      final dropdown = tester.widget<DropdownButton<MaterialSupplyRoute>>(
        _route(1),
      );
      expect(dropdown.value, MaterialSupplyRoute.subcontract);
      expect(dropdown.onChanged, isNotNull);
      await _selectRoot(tester, 1);
      await _confirm(tester);
      expect(_decisions(harness.writes.single), [
        {'actionGroupKey': 'root-action-1', 'route': 'SUBCONTRACT'},
      ]);
    },
  );

  testWidgets(
    'a repeated root ancestor on page two is read only and is not confirmed twice',
    (tester) async {
      final harness = await _pump(
        tester,
        _analysis(routes: ['SUBCONTRACT'], childrenPerProduct: 120),
      );
      await _selectRoot(tester, 1);
      await tester.ensureVisible(find.text('下一页'));
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      final ancestor = find.byKey(const ValueKey('PAGE_CONTEXT|2|PRODUCT|p1'));
      expect(ancestor, findsOneWidget);
      expect(_root(1), findsNothing);
      for (final checkbox in tester.widgetList<Checkbox>(
        find.descendant(of: ancestor, matching: find.byType(Checkbox)),
      )) {
        expect(checkbox.onChanged, isNull);
      }
      expect(find.descendant(of: ancestor, matching: _route(1)), findsNothing);
      final header = find.descendant(
        of: find.byKey(const Key('material-analysis-material-table-region')),
        matching: find.byWidgetPredicate(
          (widget) => widget is Checkbox && widget.tristate,
        ),
      );
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.text('确认路线(22)'), findsOneWidget);
      await _confirm(tester);
      final decisions = _decisions(harness.writes.single);
      expect(decisions, hasLength(22));
      expect(
        decisions.where(
          (decision) => decision['actionGroupKey'] == 'root-action-1',
        ),
        hasLength(1),
      );
      expect(
        decisions.map((decision) => decision['actionGroupKey']).toSet(),
        hasLength(22),
      );
    },
  );

  testWidgets(
    'selecting 101 root rows across pages confirms 101 unique real UUID actions',
    (tester) async {
      final harness = await _pump(
        tester,
        _analysis(
          routes: [
            for (var index = 0; index < 101; index++)
              ['BUY', 'SUBCONTRACT', 'MAKE'][index % 3],
          ],
          withChildren: false,
        ),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('material-analysis-material-table-region')),
          matching: find.byWidgetPredicate((w) => w is Checkbox && w.tristate),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('material-analysis-material-table-region')),
          matching: find.byWidgetPredicate((w) => w is Checkbox && w.tristate),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('确认路线(101)'), findsOneWidget);
      await _confirm(tester);
      final decisions = _decisions(harness.writes.single);
      expect(decisions, hasLength(101));
      expect(
        decisions.map((decision) => decision['actionGroupKey']).toSet(),
        hasLength(101),
      );
      for (final decision in decisions) {
        final index =
            int.parse((decision['actionGroupKey'] as String).split('-').last) -
            1;
        expect(decision['route'], ['BUY', 'SUBCONTRACT', 'MAKE'][index % 3]);
      }
    },
  );
}

Finder _root(int index) => find.byKey(ValueKey('material-bom-product-p$index'));
Finder _route(int index) =>
    find.byKey(ValueKey('material-route-dropdown-root-$index'));
Future<void> _selectRoot(WidgetTester tester, int index) async {
  final checkbox = find.descendant(
    of: _root(index),
    matching: find.byType(Checkbox),
  );
  await tester.ensureVisible(checkbox);
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester) async {
  final button = find.byKey(const Key('material-analysis-create-routes'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _openBucket(WidgetTester tester, String route) async {
  final entry = find.byKey(Key('material-analysis-entry-$route'));
  await tester.ensureVisible(entry);
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

Future<void> _closeBucket(WidgetTester tester) async {
  await tester.tap(find.byTooltip('返回').last);
  await tester.pumpAndSettle();
}

List<Map<String, dynamic>> _decisions(RequestOptions request) =>
    ((request.data as Map<String, dynamic>)['decisions'] as List)
        .cast<Map<String, dynamic>>();

Future<_Harness> _pump(
  WidgetTester tester,
  Map<String, dynamic> data, {
  bool generate = false,
  bool refresh = false,
  bool removeBomAfterExternalRootConfirmation = false,
}) async {
  tester.view.physicalSize = const Size(1700, 1050);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final harness = _Harness(data);
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        harness.requests.add(request);
        dynamic result = <String, dynamic>{};
        if (request.path.endsWith('/warehouses/dict')) {
          result = [
            {'id': 'warehouse', 'name': '主仓'},
          ];
        } else if (request.path.endsWith('/last-routes')) {
          result = <String, dynamic>{};
        } else if (request.path.endsWith('/default-workshops')) {
          result = [
            for (final id in (request.queryParameters['ids'] as String).split(
              ',',
            ))
              {
                'goodsId': id,
                'departmentId': 'workshop',
                'departmentName': '装配车间',
              },
          ];
        } else if (request.path == '/production/material-analyses/analysis') {
          result = harness.data;
        } else if (request.path == '/production/material-analyses/preview') {
          harness.data =
              jsonDecode(jsonEncode(harness.data)) as Map<String, dynamic>;
          harness.data['version'] = (harness.data['version'] as int) + 1;
          result = harness.data;
        } else if (request.path.endsWith('/routes') &&
            request.method == 'PUT') {
          harness.data =
              jsonDecode(jsonEncode(harness.data)) as Map<String, dynamic>;
          final byKey = {
            for (final row
                in (harness.data['flatMaterials'] as List)
                    .cast<Map<String, dynamic>>())
              row['actionGroupKey'] as String: row,
          };
          if (_decisions(
            request,
          ).any((decision) => !byKey.containsKey(decision['actionGroupKey']))) {
            harness.failedRouteResolutions++;
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.badResponse,
                response: Response<dynamic>(
                  requestOptions: request,
                  statusCode: 409,
                  data: {'code': 'CONFLICT', 'message': '原BOM已被根路线停用'},
                ),
              ),
            );
            return;
          }
          for (final decision in _decisions(request)) {
            final key = decision['actionGroupKey'] as String;
            final target = byKey[key]!;
            if (target['nodeRole'] == 'ROOT_SUPPLY' &&
                removeBomAfterExternalRootConfirmation) {
              harness.routesBeforeRoot.add(
                Map<String, String>.from(harness.confirmedRoutes),
              );
            }
            target['sourceConfirmed'] = decision['route'];
            target['routeConfirmed'] = true;
            harness.confirmedRoutes[key] = decision['route'] as String;
          }
          if (removeBomAfterExternalRootConfirmation &&
              byKey.values.any(
                (row) =>
                    row['nodeRole'] == 'ROOT_SUPPLY' &&
                    row['routeConfirmed'] == true &&
                    (row['sourceConfirmed'] == 'BUY' ||
                        row['sourceConfirmed'] == 'SUBCONTRACT'),
              )) {
            harness.data['flatMaterials'] = byKey.values
                .where((row) => row['nodeRole'] == 'ROOT_SUPPLY')
                .toList();
          }
          harness.data['version'] = (harness.data['version'] as int) + 1;
          harness.data['fingerprint'] = 'b' * 64;
          result = harness.data;
        } else if (request.path.endsWith('/issue-plans')) {
          result = {
            'analysis': harness.data,
            'plans': [
              {
                'planId': 'plan-root',
                'planNo': 'PP-ROOT',
                'status': 'APPROVED',
                'packageId': 'package-root',
                'segmentIds': ['waiting-root'],
                'drawIds': <String>[],
              },
            ],
          };
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
        sessionProvider.overrideWith(_Session.new),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionMaterialAnalysisView,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisNotify,
          if (refresh) Perm.productionMaterialAnalysisRefresh,
          if (generate) Perm.productionMaterialAnalysisGenerate,
          if (generate) Perm.productionPlanApprove,
        }),
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        departmentRepositoryProvider.overrideWithValue(_Departments()),
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

class _Harness {
  _Harness(this.data);
  Map<String, dynamic> data;
  final List<RequestOptions> requests = [];
  final Map<String, String> confirmedRoutes = {};
  final List<Map<String, String>> routesBeforeRoot = [];
  int failedRouteResolutions = 0;

  List<RequestOptions> get writes =>
      requests.where((request) => request.method == 'PUT').toList();
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
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

class _Departments implements DepartmentRepository {
  @override
  Future<List<DepartmentNode>> tree() async => [
    DepartmentNode(
      id: 'production',
      code: 'DEPT_PROD',
      name: '生产部',
      level: '部门',
      children: [
        DepartmentNode(
          id: 'workshop',
          code: 'WS-1',
          name: '装配车间',
          level: '车间',
          parentId: 'production',
          managerId: 'worker',
          managerName: '张负责人',
          children: const [],
        ),
      ],
    ),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _issuedPlanAnchors({bool partialSecondPath = false}) {
  final data =
      jsonDecode(
            jsonEncode(
              _analysis(
                routes: ['MAKE'],
                confirmed: true,
                childrenPerProduct: 6,
              ),
            ),
          )
          as Map<String, dynamic>;
  (data['allowedActions'] as List).add('REFRESH');
  final products = (data['products'] as List).cast<Map<String, dynamic>>();
  final materials = (data['flatMaterials'] as List)
      .cast<Map<String, dynamic>>();
  final root = products.single;
  root.addAll({
    'requestedQty': 10000,
    'approvedQty': 10000,
    'submittedQty': 0,
    'remainingQty': 0,
    'canSchedule': false,
    'maxSchedulableQty': 0,
    'planExecutionStatus': 'WAITING',
    'planExecutionPlannedQty': 10000,
    'latestPlanId': 'root-plan',
  });
  materials.first.addAll({
    'requiredQty': 10000,
    'shortageQty': 10000,
    'demandSupplyGapQty': 10000,
  });
  for (var index = 1; index <= 6; index++) {
    final subcontract = index == 6;
    final partial = partialSecondPath && index == 2;
    final sameGoods = index <= 2 ? 'shared-make-goods' : 'make-goods-$index';
    materials[index].addAll({
      'goodsId': sameGoods,
      'goodsCode': 'M-$index',
      'goodsName': '来源自制件 $index',
      'sourceSuggestion': subcontract ? 'SUBCONTRACT' : 'MAKE',
      'sourceConfirmed': subcontract ? 'SUBCONTRACT' : 'MAKE',
      'routeConfirmed': true,
      'requiredQty': 10000, 'shortageQty': 10000, 'demandSupplyGapQty': 10000,
      'planAnchorAnalysisLineId': 'plan-anchor-$index',
      // Direct MAKE issuance has a persistent anchor but no supply action.
      if (subcontract)
        'notifiedTargets': [
          {
            'target': 'SUBCONTRACT',
            'documentType': 'SUBCONTRACT_MAKE_TASK',
            'documentId': 'plan-anchor-$index',
            'status': 'CREATED',
            'qty': 10000,
          },
        ],
    });
    products.add({
      'analysisLineId': 'plan-anchor-$index',
      'sourceType': subcontract ? 'SUBCONTRACT_MAKE' : 'MAKE_COMPONENT',
      'parentAnalysisLineId': 'p1',
      'goodsId': sameGoods,
      'goodsCode': 'M-$index',
      'goodsName': '自制组件 $index',
      'unitId': 'piece',
      'unitName': '件',
      'unitRate': 1,
      'requestedQty': 10000,
      'approvedQty': partial ? 6000 : 10000,
      'submittedQty': 0,
      'remainingQty': partial ? 4000 : 0,
      'canSchedule': partial,
      'maxSchedulableQty': partial ? 4000 : 0,
      'readyNowQty': 0,
      'hasProductionMaterialChildren': false,
      'planExecutionStatus': index <= 3 ? 'READY' : 'WAITING',
      'planExecutionPlannedQty': partial ? 6000 : 10000,
      'latestPlanId': 'plan-$index',
    });
  }
  // The seven procurement actions belong to original BOM paths. Child plan
  // anchors have no copied material subtree and no second physical demand.
  for (var index = 1; index <= 7; index++) {
    materials.add({
      'materialLineId': 'raw-$index',
      'analysisLineId': 'p1',
      'nodeKey': 'raw-node-$index',
      'parentNodeKey': 'child-node-1-${(index - 1) % 6 + 1}',
      'nodeRole': 'BOM_COMPONENT',
      'level': 2,
      'actionGroupKey': 'raw-action-$index',
      'goodsId': 'raw-goods-$index',
      'goodsName': '采购原料 $index',
      'unitId': 'piece',
      'unitName': '件',
      'requiredQty': 10000,
      'shortageQty': 10000,
      'demandSupplyGapQty': 10000,
      'actionable': true,
      'sourceConfirmed': 'BUY',
      'sourceSuggestion': 'BUY',
      'routeConfirmed': true,
      'notifiedTargets': [
        {
          'target': 'BUY',
          'documentType': 'PURCHASE_REQUEST',
          'documentId': 'purchase-request-$index',
          'status': 'CREATED',
          'qty': 10000,
        },
      ],
    });
  }
  return data;
}

Map<String, dynamic> _analysis({
  required List<String?> routes,
  bool confirmed = false,
  bool withChildren = true,
  int childrenPerProduct = 1,
  int unitRate = 1,
}) => {
  'analysisId': 'analysis',
  'version': 3,
  'fingerprint': 'a' * 64,
  'status': 'ACTIVE',
  'warehouseId': 'warehouse',
  'warehouseIds': ['warehouse'],
  'allowedActions': [
    'VIEW',
    'CONFIRM_ROUTES',
    'NOTIFY_SUPPLY',
    'PLAN_PREVIEW',
    'GENERATE_PLAN',
  ],
  'products': [
    for (var index = 1; index <= routes.length; index++)
      {
        'analysisLineId': 'p$index',
        'sourceType': 'STOCK',
        'sourceRef': 'ROOT-$index',
        'rootMaterialLineId': 'root-$index',
        'goodsId': 'root-goods-$index',
        'goodsCode': 'P-$index',
        'goodsName': '根产品 $index',
        'unitId': unitRate == 1 ? 'piece' : 'box',
        'unitName': unitRate == 1 ? '件' : '箱',
        'unitRate': unitRate,
        'requestedQty': 10,
        'remainingQty': 10,
        'readyNowQty': 0,
        'canSchedule': true,
        'maxSchedulableQty': 10,
        'allocationPriority': index,
      },
  ],
  'flatMaterials': [
    for (var index = 1; index <= routes.length; index++) ...[
      {
        'materialLineId': 'root-$index',
        'analysisLineId': 'p$index',
        'nodeKey': 'root-node-$index',
        'nodeRole': 'ROOT_SUPPLY',
        'actionGroupKey': 'root-action-$index',
        'goodsId': 'root-goods-$index',
        'goodsCode': 'P-$index',
        'goodsName': '根产品 $index',
        'unitId': 'piece',
        'unitName': '件',
        'level': 0,
        'path': ['根产品 $index'],
        'requiredQty': 10 * unitRate,
        'shortageQty': 10 * unitRate,
        'demandSupplyGapQty': 10 * unitRate,
        'availableQty': 0,
        'allocatedAvailableQty': 0,
        'actionable': true,
        'sourceSuggestion': routes[index - 1],
        'sourceConfirmed': confirmed ? routes[index - 1] : null,
        'routeConfirmed': confirmed,
      },
      if (withChildren)
        for (var child = 1; child <= childrenPerProduct; child++)
          {
            'materialLineId': 'child-$index-$child',
            'analysisLineId': 'p$index',
            'nodeKey': 'child-node-$index-$child',
            'parentNodeKey': 'root-node-$index',
            'nodeRole': 'BOM_COMPONENT',
            'actionGroupKey': 'child-action-$index-$child',
            'goodsId': 'child-goods-$index-$child',
            'goodsCode': 'C-$index-$child',
            'goodsName': 'BOM 子料 $index-$child',
            'unitId': 'piece',
            'unitName': '件',
            'level': 1,
            'path': ['根产品 $index', 'BOM 子料 $index-$child'],
            'requiredQty': 20,
            'shortageQty': 20,
            'demandSupplyGapQty': 20,
            'actionable': true,
            'sourceSuggestion': 'BUY',
            'sourceConfirmed': null,
            'routeConfirmed': false,
          },
    ],
  ],
};

/// 行首勾选格 2026-09-11 起被「冻结」成整行 Stack 的 Positioned 兄弟
/// （横滚时钉在视口左缘，见 UtenFrozenLeadingColumn），不再是数据 Row 的后代。
/// 定位整行时必须取冻结包裹层；没有选择列的表（无冻结层）回落到 Row。
Finder _frozenRowOf(String text) {
  final frozen = find.ancestor(
    of: find.text(text).first,
    matching: find.byType(UtenFrozenLeadingColumn),
  );
  if (frozen.evaluate().isNotEmpty) return frozen.first;
  return find
      .ancestor(of: find.text(text).first, matching: find.byType(Row))
      .first;
}
