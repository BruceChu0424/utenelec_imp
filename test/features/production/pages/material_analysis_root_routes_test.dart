import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
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
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';

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
    final harness = await _pump(tester, data, refresh: true);
    expect(find.text(reason), findsWidgets);
    // 2026-09-27 自动确认挪到服务端 (ADR-102)：详情只把没被拦的 p2 数进待确认，
    // 页面静默刷新一次、由服务端确认 p2；被财务拦截的 p1 留在主表红框等放行。
    // 页面自己不发 PUT /routes。
    expect(harness.writes, isEmpty);
    expect(harness.previews, hasLength(1));
    expect(harness.confirmedRoutes, {'root-action-2': 'BUY'});
    expect(find.text('确认路线(1)'), findsNothing);
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
          'issuedPlanQty': 10,
        });
        final root =
            (data['flatMaterials'] as List).single as Map<String, dynamic>;
        if (!explicitRole) root.remove('nodeRole');
        await _pump(tester, data);
        await _openBucket(tester, 'workshop');
        expect(_taskSegment('等待下达车间 (0)'), findsOneWidget);
        expect(_taskSegment('已下达 (1)'), findsOneWidget);
        await tester.tap(_taskSegment('已下达 (1)'));
        await tester.pumpAndSettle();
        expect(find.text('车间已收到 · 等待物料'), findsOneWidget);
        // 2026-09-14 起货品身份格拆两行：主行名称、副行「编号 · 颜色」。
        expect(find.text('根产品 1'), findsWidgets);
        expect(find.text('P-1'), findsWidgets);
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
      expect(_taskSegment('等待下达车间 (0)'), findsOneWidget);
      expect(_taskSegment('已下达 (7)'), findsOneWidget);
      await tester.tap(_taskSegment('已下达 (7)'));
      await tester.pumpAndSettle();
      expect(find.text('物料齐套 · 可开工'), findsNWidgets(3));
      expect(find.text('车间已收到 · 等待物料'), findsNWidgets(4));
      expect(find.textContaining(RegExp(r'创建生产计划.*\(1\)')), findsNothing);
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
      expect(_taskSegment('等待下达车间 (0)'), findsOneWidget);
      expect(_taskSegment('已下达 (7)'), findsOneWidget);
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
      expect(_taskSegment('等待下达车间 (1)'), findsOneWidget);
      expect(_taskSegment('已下达 (7)'), findsOneWidget);
      expect(find.text('自制组件 1'), findsNothing);
      expect(find.text('自制组件 2'), findsOneWidget);
      expect(find.text('来源自制件 2'), findsNothing);
      // 2026-09-22 起外层桶表只读：没有数量框，数量进「核对并下单」页再看。
      final row = _frozenRowOf('自制组件 2');
      expect(find.byType(TextField), findsNothing);
      await tester.tap(
        find.descendant(of: row, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'创建生产计划.*\(1\)')), findsOneWidget);
      await tester.tap(_taskSegment('已下达 (7)'));
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'创建生产计划.*\(1\)')), findsNothing);
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .where((checkbox) => checkbox.onChanged != null),
        isNotEmpty,
      );
      await tester.tap(_taskSegment('等待下达车间 (1)'));
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
      // 进「父件 + 下层一起下单」页：数量默认 = 剩余需求 4000，车间由学习默认带出；
      // 来源节点下挂着的采购原料也展开为下层行(默认勾上)，一键下单先父件后采购。
      expect(
        tester.widget<TextField>(_cascadeSeedQty()).controller!.text,
        '4000',
      );
      await tester.tap(
        find.byKey(const Key('material-preparation-order-submit')),
      );
      await tester.pumpAndSettle();
      if (find.byType(AlertDialog).evaluate().isNotEmpty) {
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('确认下单'),
          ),
        );
        await tester.pumpAndSettle();
      }
      final groups = harness.requests
          .where((request) => request.path.endsWith('/aggregate-orders/submit'))
          .expand(
            (request) =>
                (request.data as Map<String, dynamic>)['groups'] as List,
          )
          .cast<Map<String, dynamic>>()
          .where((group) => group['route'] == 'MAKE')
          .toList();
      expect(groups, hasLength(1));
      expect(groups.single['materialLineIds'], ['child-1-2']);
      expect(double.parse(groups.single['qty'].toString()), 4000);
      expect((data['products'] as List), hasLength(7));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an issued child with missing authoritative assignment cannot be selected from the workshop bucket',
    (tester) async {
      final data = _issuedPlanAnchors(partialSecondPath: true);
      final child = (data['products'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere(
            (product) => product['analysisLineId'] == 'plan-anchor-2',
          );
      child.remove('planExecutionResponsibleId');
      final harness = await _pump(tester, data, generate: true);
      await _openBucket(tester, 'workshop');
      final row = _frozenRowOf('自制组件 2');
      final check = find.descendant(of: row, matching: find.byType(Checkbox));
      expect(tester.widget<Checkbox>(check).onChanged, isNull);
      expect(
        harness.requests.where(
          (request) =>
              request.path.endsWith('/aggregate-orders/submit') ||
              request.path.endsWith('/issue-plans'),
        ),
        isEmpty,
      );
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
      expect(_taskSegment('等待下达车间 (0)'), findsOneWidget);
      expect(_taskSegment('已下达 (6)'), findsOneWidget);
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
    '501 mixed BOM routes are confirmed by one server refresh, not chunked page writes',
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
        refresh: true,
        removeBomAfterExternalRootConfirmation: true,
      );
      // 2026-09-27 自动确认挪到服务端 (ADR-102)：502 组不再由页面「先深后浅、
      // 500 一批」分块 PUT，而是一次静默刷新、服务端同一事务里全部确认；采购根
      // 停用原 BOM 也在那次重算里完成，不会出现后一块引用已停用行的 409。
      expect(harness.writes, isEmpty);
      expect(harness.previews, hasLength(1));
      expect(harness.failedRouteResolutions, 0);
      expect(depths, hasLength(501));
      expect(harness.confirmedRoutes, {
        ...expectedRoutes,
        '000-root-action': 'BUY',
      });
      expect(harness.data['flatMaterials'], hasLength(1));
      expect(
        (harness.previews.single.data as Map<String, dynamic>)['version'],
        3,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'root shares one product row and confirms only its own actual route',
    (tester) async {
      final harness = await _pump(
        tester,
        _analysis(routes: ['SUBCONTRACT', 'BUY', 'MAKE']),
        refresh: true,
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
      // 2026-09-27 自动确认挪到服务端 (ADR-102)：一次静默刷新，每个根按各自的
      // 主档建议落自己的路线，互不串台；页面不发 PUT、没有确认按钮。
      expect(harness.writes, isEmpty);
      expect(harness.previews, hasLength(1));
      expect(
        {
          for (final entry in harness.confirmedRoutes.entries)
            if (entry.key.startsWith('root-action-')) entry.key: entry.value,
        },
        {
          'root-action-1': 'SUBCONTRACT',
          'root-action-2': 'BUY',
          'root-action-3': 'MAKE',
        },
      );
      for (final (index, route) in [
        (1, 'subcontract'),
        (2, 'buy'),
        (3, 'make'),
      ]) {
        expect(tester.widget<UtenDropdownField>(_route(index)).value, route);
      }
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
    // 2026-09-22(ADR-102)：「在途未到」独立列退役，它那句「10 · 已锚定」改到
    // 「还缺数量」的悬浮说明里。这里直接读 Tooltip 的文案，断言这条事实没丢。
    final shortageTooltip = tester.widget<Tooltip>(
      find.descendant(
        of: _root(1),
        matching: find.byKey(
          const ValueKey('material-analysis-net-shortage-root-1'),
        ),
      ),
    );
    expect(shortageTooltip.message, contains('已安排但还没合格入库 10'));
    expect(
      find.descendant(of: _root(1), matching: find.text('10 件')),
      findsWidgets,
      reason: '数量列 2026-10-10 起内联单位',
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
        find.descendant(of: root, matching: find.text('200 件')),
        findsWidgets,
        reason: '数量列 2026-10-10 起内联单位',
      );
      expect(
        find.descendant(of: root, matching: find.textContaining('件')),
        findsWidgets,
      );
      await _openBucket(tester, 'workshop');
      expect(find.text('根产品 1'), findsOneWidget);
      // 2026-09-22 起桶表只留 8 列，「类型」列退役(顶层与子层同构，一律自制候选)。
      expect(
        find.byKey(const Key('material-analysis-bucket-create-tasks')),
        findsNothing,
      );
      final productRow = _frozenRowOf('根产品 1');
      // 2026-09-06 统一流程词表：未下达的自制任务显示第一步「等待下达车间」，
      // 不区分下层齐套（齐套与否由计划审批后的执行段 WAITING/READY 自动判断）。
      expect(find.text('等待下达车间'), findsWidgets);
      await tester.tap(
        find.descendant(of: productRow, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'创建生产计划.*\(1\)')), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('material-analysis-bucket-action-ready')),
      );
      await tester.pumpAndSettle();
      // 2026-09-22 起数量在「核对并下单」页里：默认 = 剩余需求 10，点「下单」提交。
      expect(
        tester.widget<TextField>(_cascadeSeedQty()).controller!.text,
        '200', // 主表统一显示基本单位，提交计划时按20件/箱转换回10箱。
      );
      await tester.tap(
        find.byKey(const Key('material-preparation-order-submit')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('确认下单'),
        ),
      );
      await tester.pumpAndSettle();
      final issueRequest = harness.requests.singleWhere(
        (request) => request.path.endsWith('/issue-plans'),
      );
      expect((issueRequest.data as Map<String, dynamic>)['lines'], [
        // 没人改过的允许超产比例不带(ADR-129 §2.10)，由服务端按货品默认填写。
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
      // 2026-09-25 确认路线退役修订：主档能定路线(建议 MAKE)的根自动确认、
      // 照旧进车间桶；主档来源为空的根(REVIEW)不自动确认，仍不进车间桶
      // (入口计数 0 且灰显不可点)，留在主表红框等人选。2026-09-27 起确认在
      // 服务端：详情报待确认 → 页面静默刷新一次，零 PUT。
      final confirmed = await _pump(
        tester,
        _analysis(routes: ['MAKE'], withChildren: false),
        generate: true,
        refresh: true,
      );
      expect(confirmed.writes, isEmpty);
      expect(confirmed.previews, hasLength(1));
      expect(confirmed.confirmedRoutes, {'root-action-1': 'MAKE'});
      final workshopEntry = find.byKey(
        const Key('material-analysis-entry-workshop'),
      );
      expect(workshopEntry, findsOneWidget);
      expect(
        tester.widget<InkWell>(workshopEntry).onTap,
        isNotNull,
        reason: '主档自制的根自动确认后进入车间桶',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      final review = await _pump(
        tester,
        _analysis(routes: [null], withChildren: false),
        generate: true,
        refresh: true,
      );
      expect(review.writes, isEmpty, reason: 'REVIEW 根不自动确认');
      expect(review.previews, isEmpty, reason: '详情不报待确认就不刷新');
      expect(find.text('路线待确认'), findsWidgets);
      expect(
        find.byKey(const Key('material-analysis-entry-workshop')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<InkWell>(
              find.byKey(const Key('material-analysis-entry-workshop')),
            )
            .onTap,
        isNull,
        reason: 'REVIEW 根未确认仍不进车间桶',
      );
      // 确认自制后顶层进入车间桶、共用下层齐套词汇的契约由下方
      // 'confirmed root MAKE waits for materials...' 用例锁定。
      expect(
        review.requests.where((request) => request.path.endsWith('/notify')),
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
      final dropdown = tester.widget<UtenDropdownField>(_route(1));
      // 2026-09-25 确认路线退役：主档来源为空的根显示空选（不再兜底委外），
      // 红框指路；选好即自动保存。
      expect(dropdown.value, isNull);
      expect(dropdown.enabled, isTrue);
      expect(
        find.byKey(const ValueKey('material-route-pending-root-1')),
        findsOneWidget,
      );
      expect(harness.writes, isEmpty, reason: 'REVIEW 根不自动确认');
      await tester.ensureVisible(_route(1));
      await tester.tap(_route(1));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('采购').last);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(_decisions(harness.writes.single), [
        {'actionGroupKey': 'root-action-1', 'route': 'BUY'},
      ]);
    },
  );

  testWidgets(
    '120 children render on one page without a pager and confirm once',
    (tester) async {
      final harness = await _pump(
        tester,
        _analysis(routes: ['SUBCONTRACT'], childrenPerProduct: 120),
        refresh: true,
      );
      // 2026-09-27 主表去分页 + 自动确认挪到服务端 (ADR-102)：120 行一页直下、
      // 翻页条退役；一次静默刷新、服务端按操作组一次确认 121 组，滚到深处
      // 也不触发第二次确认。
      expect(harness.writes, isEmpty);
      expect(harness.previews, hasLength(1));
      expect(harness.confirmedRoutes, hasLength(121));
      expect(harness.confirmedRoutes['root-action-1'], 'SUBCONTRACT');
      expect(find.text('下一页'), findsNothing, reason: '主表翻页条已退役');
      await tester.drag(
        find.byKey(const Key('material-analysis-material-table')),
        const Offset(0, -4000),
      );
      await tester.pumpAndSettle();
      expect(harness.previews, hasLength(1), reason: '滚动不触发第二次确认');
      expect(harness.writes, isEmpty);
    },
  );

  testWidgets(
    '101 root rows are confirmed server-side as 101 unique real UUID actions',
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
        refresh: true,
      );
      // 2026-09-27 自动确认挪到服务端：一次静默刷新确认全部 101 个根，每个按
      // 各自主档建议、真实身份唯一不重复；页面零 PUT。
      expect(harness.writes, isEmpty);
      expect(harness.previews, hasLength(1));
      expect(harness.confirmedRoutes, hasLength(101));
      for (final entry in harness.confirmedRoutes.entries) {
        final index = int.parse(entry.key.split('-').last) - 1;
        expect(entry.value, ['BUY', 'SUBCONTRACT', 'MAKE'][index % 3]);
      }
    },
  );
}

Finder _root(int index) => find.byKey(ValueKey('material-bom-product-p$index'));
Finder _route(int index) =>
    find.byKey(ValueKey('material-route-dropdown-root-$index'));
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
            {'id': 'warehouse', 'name': '主仓', 'selectableForNew': true},
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
          // 详情：服务端按同一判据数出「还能自动确认」的组数 (ADR-102 2026-09-27)。
          result = {
            ...harness.data,
            'autoConfirmedRouteCount': 0,
            'pendingAutoConfirmRouteCount': _serverAutoConfirmable(
              harness.data,
            ).length,
          };
        } else if (request.path == '/production/material-analyses/preview') {
          // 刷新：服务端在同一次重算里按货品档案确认，版本只涨一次。
          harness.data =
              jsonDecode(jsonEncode(harness.data)) as Map<String, dynamic>;
          final confirmable = _serverAutoConfirmable(harness.data);
          for (final row in confirmable) {
            row['sourceConfirmed'] = row['sourceSuggestion'];
            row['routeConfirmed'] = true;
            harness.confirmedRoutes[row['actionGroupKey'] as String] =
                row['sourceSuggestion'] as String;
          }
          if (removeBomAfterExternalRootConfirmation) {
            _removeBomUnderExternalRoot(harness.data);
          }
          harness.data['version'] = (harness.data['version'] as int) + 1;
          harness.data['fingerprint'] = 'c' * 64;
          result = {
            ...harness.data,
            'autoConfirmedRouteCount': confirmable.length,
            'pendingAutoConfirmRouteCount': 0,
          };
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
          if (removeBomAfterExternalRootConfirmation) {
            _removeBomUnderExternalRoot(harness.data);
          }
          harness.data['version'] = (harness.data['version'] as int) + 1;
          harness.data['fingerprint'] = 'b' * 64;
          result = harness.data;
        } else if (request.path.endsWith('/aggregate-orders/preview')) {
          final body = request.data as Map<String, dynamic>;
          result = {
            'analysisId': harness.data['analysisId'],
            'version': harness.data['version'],
            'fingerprint': harness.data['fingerprint'],
            'previewFingerprint': 'e' * 64,
            'analysis': harness.data,
            'groups': [
              for (final group
                  in (body['groups'] as List).cast<Map<String, dynamic>>())
                {
                  'clientGroupKey': group['clientGroupKey'],
                  'route': group['route'],
                  'goodsId':
                      ((harness.data['flatMaterials'] as List)
                              .cast<Map<String, dynamic>>()
                              .firstWhere(
                                (m) =>
                                    m['materialLineId'] ==
                                    (group['materialLineIds'] as List).first,
                              )
                          as Map)['goodsId'],
                  'requestedQty': double.parse(group['qty'].toString()),
                  'sources': [
                    for (final id in group['materialLineIds'] as List)
                      {
                        'materialLineId': id,
                        'sourceLabel': id,
                        'allocatedQty': double.parse(group['qty'].toString()),
                      },
                  ],
                  'sharedBomChildren': <Object>[],
                },
            ],
          };
        } else if (request.path.endsWith('/aggregate-orders/submit')) {
          result = {
            'analysis': harness.data,
            'replayed': false,
            'batches': <Object>[],
            'materialIdentityBridges': <Object>[],
          };
        } else if (request.path.endsWith('/issue-plans/preview')) {
          // 2026-09-22 起下达车间一律进「父件 + 下层一起下单」页，进页前按本批
          // 数量向服务端要一份预览；本 harness 不算量，原样回当前快照。
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
  List<RequestOptions> get previews => requests
      .where(
        (request) =>
            request.method == 'POST' && request.path.endsWith('/preview'),
      )
      .toList();
}

/// 服务端自动确认判据的夹具简化版 (MaterialAnalysisRouteAutoConfirm)：未确认、
/// 主档建议非空 (非 REVIEW)、所属产品没被计划闸挡住的操作组。
List<Map<String, dynamic>> _serverAutoConfirmable(Map<String, dynamic> data) {
  final blocked = {
    ...((data['planningBlockedReasons'] as Map?) ?? const {}).keys,
  };
  return [
    for (final row
        in (data['flatMaterials'] as List).cast<Map<String, dynamic>>())
      if (row['routeConfirmed'] != true &&
          row['sourceSuggestion'] != null &&
          !blocked.contains(row['analysisLineId']))
        row,
  ];
}

/// 根确认为外购/委外后，服务端同一次重算停用它下面的原 BOM 行。
void _removeBomUnderExternalRoot(Map<String, dynamic> data) {
  final rows = (data['flatMaterials'] as List).cast<Map<String, dynamic>>();
  if (rows.any(
    (row) =>
        row['nodeRole'] == 'ROOT_SUPPLY' &&
        row['routeConfirmed'] == true &&
        (row['sourceConfirmed'] == 'BUY' ||
            row['sourceConfirmed'] == 'SUBCONTRACT'),
  )) {
    data['flatMaterials'] = rows
        .where((row) => row['nodeRole'] == 'ROOT_SUPPLY')
        .toList();
  }
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
    'issuedPlanQty': 10000,
    'latestPlanId': 'root-plan',
    'planExecutionWorkshopId': 'workshop',
    'planExecutionWorkshopName': '装配车间',
    'planExecutionResponsibleId': 'worker',
    'planExecutionResponsibleName': '生产员',
  });
  materials.first.addAll({
    'requiredQty': 10000,
    'shortageQty': 10000,
    'demandSupplyGapQty': 10000,
    'additionalSupplyRecommendedQty': 10000,
  });
  for (var index = 1; index <= 6; index++) {
    final partial = partialSecondPath && index == 2;
    final sameGoods = index <= 2 ? 'shared-make-goods' : 'make-goods-$index';
    materials[index].addAll({
      'goodsId': sameGoods,
      'goodsCode': 'M-$index',
      'goodsName': '来源自制件 $index',
      'sourceSuggestion': 'MAKE',
      'sourceConfirmed': 'MAKE',
      'routeConfirmed': true,
      'requiredQty': 10000, 'shortageQty': 10000, 'demandSupplyGapQty': 10000,
      'additionalSupplyRecommendedQty': 10000,
      // Direct MAKE issuance has a persistent anchor but no supply action.
      'planAnchorAnalysisLineId': 'plan-anchor-$index',
    });
    products.add({
      'analysisLineId': 'plan-anchor-$index',
      'sourceType': 'MAKE_COMPONENT',
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
      'issuedPlanQty': partial ? 6000 : 10000,
      'latestPlanId': 'plan-$index',
      'planExecutionWorkshopId': 'workshop',
      'planExecutionWorkshopName': '装配车间',
      'planExecutionResponsibleId': 'worker',
      'planExecutionResponsibleName': '生产员',
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
      'additionalSupplyRecommendedQty': 10000,
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
    'REFRESH',
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
        'additionalSupplyRecommendedQty': 10 * unitRate,
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
            'additionalSupplyRecommendedQty': 20,
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

/// 「核对并下单」页里树顶那一行的数量框(2026-09-22 起外层桶表只读，数量只在
/// 这里填)；一次只进一行时它就是第一个。
Finder _cascadeSeedQty() => find
    .byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.key is ValueKey<String> &&
          ((widget.key! as ValueKey<String>).value.startsWith(
                'material-analysis-order-qty-',
              ) ||
              (widget.key! as ValueKey<String>).value.startsWith(
                'material-analysis-append-qty-',
              )),
    )
    .first;

Finder _taskSegment(String label) {
  final match = RegExp(r'^(.*) \((\d+)\)$').firstMatch(label);
  final raw = match?.group(1) ?? label;
  final name = raw == '已下达' || raw == '进行中'
      ? '进行中'
      : raw.startsWith('等待下')
      ? '待下单'
      : raw;
  final count = match == null ? null : int.parse(match.group(2)!);
  return find.byWidgetPredicate(
    (widget) =>
        widget is UtenSegmentBadgeLabel &&
        widget.label == name &&
        (count == null || widget.count == count),
  );
}
