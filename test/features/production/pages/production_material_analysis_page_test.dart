import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  testWidgets('fresh analysis exposes audited manual source types', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {Perm.productionMaterialAnalysisManage},
      seeded: false,
    );

    expect(find.text('手工计划（返工 / 试制 / 样品 / 备库）'), findsOneWidget);
    expect(find.text('物料分析记录'), findsOneWidget);
    expect(find.text('生产计划历史'), findsOneWidget);
    expect(find.byKey(const Key('manual-source-ref')), findsOneWidget);
    expect(find.text('同一需求请始终使用同一个编号'), findsOneWidget);
    expect(find.byKey(const Key('manual-source-goods')), findsOneWidget);
    expect(find.byKey(const Key('manual-source-reason')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('manual-source-')));
    await tester.pumpAndSettle();
    expect(find.text('返工'), findsOneWidget);
    expect(find.text('试制'), findsOneWidget);
    expect(find.text('样品'), findsOneWidget);
    expect(find.text('备库'), findsOneWidget);
    expect(find.text('其他'), findsOneWidget);
  });

  testWidgets('seeded manual analysis sends the stable demand reference', (
    tester,
  ) async {
    final harness = await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {Perm.productionMaterialAnalysisManage},
      sources: const [
        MaterialAnalysisSourceInput(
          sourceType: 'REWORK',
          sourceRef: 'RW-20260808-001',
          goodsId: 'goods-1',
          unitId: 'unit-1',
          requestedQty: 3,
          sourceReason: '客诉返工',
        ),
      ],
    );

    final request = harness.requests.singleWhere(
      (value) => value.path == '/production/material-analyses/preview',
    );
    expect((request.data as Map<String, dynamic>)['sources'], [
      {
        'sourceType': 'REWORK',
        'sourceRef': 'RW-20260808-001',
        'goodsId': 'goods-1',
        'unitId': 'unit-1',
        'requestedQty': 3.0,
        'sourceReason': '客诉返工',
      },
    ]);
  });

  testWidgets(
    'existing writable analysis auto-refreshes from the full persisted source set',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {Perm.productionMaterialAnalysisManage},
        allowedActions: const ['REFRESH'],
        analysisId: 'analysis-1',
      );

      expect(
        harness.requests.where(
          (request) =>
              request.method == 'GET' &&
              request.path == '/production/material-analyses/analysis-1',
        ),
        hasLength(1),
      );
      final refresh = harness.requests.singleWhere(
        (request) =>
            request.method == 'POST' &&
            request.path == '/production/material-analyses/preview',
      );
      final sources =
          (refresh.data! as Map<String, dynamic>)['sources'] as List;
      // The seed deliberately contains only one selected source. Reopening the
      // persisted joint analysis must refresh both original user sources and
      // must not submit the system-derived MAKE_COMPONENT child.
      expect(sources, hasLength(2));
      expect(
        sources.any(
          (source) => (source as Map).containsKey('salesOrderItemId'),
        ),
        isTrue,
      );
      expect(
        sources.any((source) => (source as Map)['sourceType'] == 'STOCK'),
        isTrue,
      );
      expect(find.text('第二测试产品'), findsOneWidget);
    },
  );

  testWidgets(
    'resumed VIEW-only analysis never mutates its persisted snapshot',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {Perm.productionMaterialAnalysisManage},
        allowedActions: const ['VIEW'],
        analysisId: 'analysis-1',
        seeded: false,
      );
      expect(
        harness.requests.where(
          (request) =>
              request.method == 'POST' &&
              request.path == '/production/material-analyses/preview',
        ),
        isEmpty,
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.refresh_rounded),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'accept-all-suggested-routes bulk-confirms concrete suggestions without reason',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
        },
        allowedActions: const ['CONFIRM_ROUTES'],
        analysisId: 'analysis-1',
        seeded: false,
      );
      // Same material on two BOM paths is now two independent decisions.
      final acceptButton = find.text('采纳建议路线（2）');
      expect(acceptButton, findsOneWidget);
      await tester.ensureVisible(acceptButton);
      await tester.pumpAndSettle();
      await tester.tap(acceptButton);
      await tester.pumpAndSettle();

      final routeRequest = harness.requests.singleWhere(
        (request) => request.method == 'PUT',
      );
      expect(
        routeRequest.path,
        '/production/material-analyses/analysis-1/routes',
      );
      final decisions =
          (routeRequest.data! as Map<String, dynamic>)['decisions'] as List;
      expect(decisions, hasLength(2));
      expect(
        decisions
            .cast<Map<String, dynamic>>()
            .map((decision) => decision['actionGroupKey'])
            .toSet(),
        {'action-material-path-1', 'action-material-path-2'},
      );
      for (final decision in decisions.cast<Map<String, dynamic>>()) {
        expect(decision['route'], 'BUY');
        // Accepting the suggestion (route == suggestion) needs no reason.
        expect(decision.containsKey('reason'), isFalse);
      }
    },
  );

  testWidgets(
    'makeComponent card shows parent assembly and ready items sort first',
    (tester) async {
      final json = _analysisJson(const ['PLAN_PREVIEW', 'GENERATE_PLAN']);
      final products = json['products']! as List<dynamic>;
      // Top product is blocked (readyNowQty 0); a self-make sub-assembly is
      // plan-ready and linked back to it.
      (products[0] as Map<String, dynamic>)
        ..['goodsName'] = '顶级插座'
        ..['readyNowQty'] = 0;
      products.add({
        'analysisLineId': 'make-comp-1',
        'sourceType': 'MAKE_COMPONENT',
        'goodsCode': 'SUB-A',
        'goodsName': '自制子件A',
        'parentAnalysisLineId': 'product-line-1',
        'parentGoodsName': '顶级插座',
        'requestedQty': 10,
        'remainingQty': 10,
        'readyNowQty': 6,
        'readinessRatio': 0.6,
        'productionBomPolicy': 'DIRECT_MAKE',
        'missingBom': false,
        'bomOverrideRequired': false,
        'hasActiveBom': false,
        'allocationPriority': 2,
      });
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: json,
      );

      // The self-make card surfaces the parent assembly it feeds into.
      expect(find.textContaining('用于组装 顶级插座'), findsOneWidget);
      // Bottom-up ordering: the plan-ready sub-assembly renders before the
      // still-blocked top product (Wrap lays children out left-to-right).
      final subAssembly = find.byKey(
        const ValueKey('material-analysis-product-make-comp-1'),
      );
      final topProduct = find.byKey(
        const ValueKey('material-analysis-product-product-line-1'),
      );
      expect(subAssembly, findsOneWidget);
      expect(topProduct, findsOneWidget);
      expect(
        tester.getTopLeft(subAssembly).dx,
        lessThan(tester.getTopLeft(topProduct).dx),
      );
      await tester.tap(
        find.byKey(
          const ValueKey('material-analysis-product-select-make-comp-1'),
        ),
      );
      await tester.pump();
      expect(find.text('安排子件生产（1）'), findsOneWidget);
    },
  );

  testWidgets(
    'BOM paths stay independent and suggested route can be adopted inline',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisGenerate,
        },
        allowedActions: const ['CONFIRM_ROUTES'],
      );

      final firstRow = find.byKey(
        const ValueKey('material-bom-node-material-path-1'),
      );
      final secondRow = find.byKey(
        const ValueKey('material-bom-node-material-path-2'),
      );
      await tester.scrollUntilVisible(
        firstRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(firstRow, findsOneWidget);
      expect(secondRow, findsOneWidget);
      expect(find.textContaining('涉及 2 条路径'), findsNothing);
      expect(
        find.descendant(
          of: firstRow,
          matching: find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
        ),
        findsNothing,
      );
      expect(find.textContaining('测试产品 → 组件 A'), findsNothing);
      final details = find.byKey(
        const ValueKey('material-node-details-toggle-material-path-1'),
      );
      final semantics = tester.ensureSemantics();
      expect(tester.getSize(details).height, greaterThanOrEqualTo(48));
      expect(tester.getSemantics(details).label, contains('展开共享紧固件详情'));
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(tester.getSemantics(details).label, contains('收起共享紧固件详情'));
      semantics.dispose();
      final firstDropdown = find.descendant(
        of: firstRow,
        matching: find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
      );
      final dropdown = tester
          .widget<DropdownButtonFormField<MaterialSupplyRoute>>(firstDropdown);
      expect(dropdown.initialValue, isNull);
      expect(find.textContaining('路径：测试产品'), findsOneWidget);
      final adopt = find.byKey(
        const ValueKey('material-adopt-route-material-path-1'),
      );
      expect(
        find.descendant(of: firstRow, matching: find.text('采用采购')),
        findsOneWidget,
      );
      await tester.ensureVisible(adopt);
      await tester.pumpAndSettle();
      await tester.tap(adopt);
      await tester.pumpAndSettle();

      final routeRequest = harness.requests.singleWhere(
        (request) => request.method == 'PUT',
      );
      expect(
        routeRequest.path,
        '/production/material-analyses/analysis-1/routes',
      );
      expect((routeRequest.data! as Map<String, dynamic>)['decisions'], [
        {'actionGroupKey': 'action-material-path-1', 'route': 'BUY'},
      ]);
    },
  );

  testWidgets(
    'route override requires a reason and cancel keeps empty default',
    (tester) async {
      final json = _analysisJson(const ['CONFIRM_ROUTES']);
      json['flatMaterials'] = [
        _materialJson(
          id: 'material-path-1',
          level: 2,
          path: ['测试产品', '组件 A', '共享紧固件'],
          routeConfirmed: false,
        ),
      ];
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
        },
        allowedActions: const ['CONFIRM_ROUTES'],
        analysisJson: json,
      );

      await _chooseRoute(tester, '自制');
      expect(find.byKey(const Key('material-route-reason')), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('确认路线（0）'), findsNothing);
      expect(
        tester
            .widget<DropdownButtonFormField<MaterialSupplyRoute>>(
              find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
            )
            .initialValue,
        isNull,
      );

      await _chooseRoute(tester, '自制');
      await tester.enterText(
        find.byKey(const Key('material-route-reason')),
        '交期紧急，改为车间自制',
      );
      await tester.tap(find.text('确认路线'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认路线（1）'));
      await tester.pumpAndSettle();

      final routeRequest = harness.requests.singleWhere(
        (request) => request.method == 'PUT',
      );
      expect(routeRequest.data, {
        'version': 3,
        'fingerprint': 'a' * 64,
        'idempotencyKey': isA<String>(),
        'decisions': [
          {
            'actionGroupKey': 'action-material-path-1',
            'route': 'MAKE',
            'reason': '交期紧急，改为车间自制',
          },
        ],
      });
    },
  );

  testWidgets(
    'allowedActions VIEW blocks every server write despite local permissions',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisNotify,
          Perm.productionMaterialAnalysisGenerate,
          Perm.productionPlanApprove,
          Perm.productionMaterialAnalysisReallocate,
        },
        allowedActions: const ['VIEW'],
      );

      expect(find.byKey(const Key('material-analysis-generate')), findsNothing);
      expect(find.text('生成并批准'), findsNothing);
      expect(
        find.byKey(const Key('material-analysis-priority-edit')),
        findsNothing,
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.refresh_rounded),
            )
            .onPressed,
        isNull,
      );
      final firstRow = find.byKey(
        const ValueKey('material-bom-node-material-path-1'),
      );
      final adopt = find.descendant(
        of: firstRow,
        matching: find.byKey(
          const ValueKey('material-adopt-route-material-path-1'),
        ),
      );
      expect(tester.widget<OutlinedButton>(adopt).onPressed, isNull);
      await tester.tap(
        find.byKey(
          const ValueKey('material-node-details-toggle-material-path-1'),
        ),
      );
      await tester.pumpAndSettle();
      final dropdown = find.descendant(
        of: firstRow,
        matching: find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
      );
      expect(
        tester
            .widget<DropdownButtonFormField<MaterialSupplyRoute>>(dropdown)
            .onChanged,
        isNull,
      );
      expect(find.byKey(const Key('material-analysis-generate')), findsNothing);
      expect(
        harness.requests.where(
          (request) =>
              request.path.endsWith('/routes') ||
              request.path.endsWith('/notify') ||
              request.path.endsWith('/generate-plan'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets(
    'inactive deep node still shows its own demand allocation and warehouse stock',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(520, 900),
        permissions: const {Perm.productionMaterialAnalysisManage},
        allowedActions: const ['VIEW'],
      );

      final dependencyRow = find.byKey(
        const ValueKey('material-bom-node-dependency-node-1'),
      );
      await tester.scrollUntilVisible(
        dependencyRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: dependencyRow, matching: find.text('需 20')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dependencyRow, matching: find.text('配 4')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dependencyRow, matching: find.text('现货 7')),
        findsOneWidget,
      );
      expect(find.textContaining('路径：测试产品'), findsNothing);
      expect(find.textContaining('随上级件'), findsNothing);
      expect(
        find.descendant(
          of: dependencyRow,
          matching: find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'allocation priority cancel is local and confirm writes the complete CAS order',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisReallocate,
        },
        allowedActions: const ['REALLOCATE'],
      );

      await tester.tap(
        find.byKey(const Key('material-analysis-priority-edit')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('material-analysis-priority-editor')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('material-priority-down-0')),
      );
      await tester.tap(
        find.byKey(const Key('material-analysis-priority-cancel')),
      );
      await tester.pumpAndSettle();
      expect(
        harness.requests.where(
          (request) => request.path.endsWith('/allocation-priorities'),
        ),
        isEmpty,
      );

      await tester.tap(
        find.byKey(const Key('material-analysis-priority-edit')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('material-priority-down-0')),
      );
      await tester.tap(
        find.byKey(const Key('material-analysis-priority-save')),
      );
      await tester.pumpAndSettle();

      final request = harness.requests.singleWhere(
        (request) => request.path.endsWith('/allocation-priorities'),
      );
      expect(request.data, {
        'version': 3,
        'fingerprint': 'a' * 64,
        'idempotencyKey': isA<String>(),
        'items': [
          {'analysisLineId': 'product-line-2', 'priority': 1},
          {'analysisLineId': 'product-line-1', 'priority': 2},
        ],
      });
    },
  );

  testWidgets('compact allocation priority editor stays reachable and usable', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(375, 900),
      permissions: const {
        Perm.productionMaterialAnalysisManage,
        Perm.productionMaterialAnalysisReallocate,
      },
      allowedActions: const ['REALLOCATE'],
    );

    await tester.tap(find.byKey(const Key('material-analysis-priority-edit')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-priority-editor')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('material-priority-down-0')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact layout defaults to the full independent BOM tree', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(375, 900),
      permissions: const {Perm.productionMaterialAnalysisManage},
      allowedActions: const ['VIEW'],
    );

    final deepRow = find.byKey(
      const ValueKey('material-bom-node-material-path-2'),
    );
    await tester.scrollUntilVisible(
      deepRow,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.byKey(const ValueKey('material-bom-node-material-path-1')),
      findsOneWidget,
    );
    expect(deepRow, findsOneWidget);
    expect(find.textContaining('涉及 2 条路径'), findsNothing);
    expect(
      find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
      findsNothing,
    );
    expect(find.textContaining('需 '), findsWidgets);
    expect(find.textContaining('配 '), findsWidgets);
    expect(find.textContaining('缺 '), findsWidgets);
    expect(find.text('计划日期 未设置'), findsNothing);
    expect(find.byKey(const Key('material-analysis-generate')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'route rows support tri-state selection, deep-green state and subset notify',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _buySelectionAnalysisJson(),
      );

      final header = find.byKey(
        const ValueKey('material-route-select-all-BUY'),
      );
      await tester.scrollUntilVisible(
        header,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(tester.element(header), alignment: 0.5);
      await tester.pump();
      expect(tester.widget<Checkbox>(header).value, isFalse);

      await tester.tap(header);
      await tester.pump();
      expect(tester.widget<Checkbox>(header).value, isTrue);
      expect(find.text('通知采购（2）'), findsOneWidget);

      final first = find.byKey(
        const ValueKey('material-bom-select-buy-line-1'),
      );
      await tester.tap(first);
      await tester.pump();
      expect(tester.widget<Checkbox>(header).value, isNull);
      expect(find.text('通知采购（1）'), findsOneWidget);

      final selectedRow = tester.widget<Container>(
        find.byKey(const ValueKey('material-bom-node-buy-node-2')),
      );
      expect(
        ((selectedRow.decoration as BoxDecoration).color),
        UtenColors.deepGreen,
      );

      final subcontract = find.byKey(
        const ValueKey('material-bom-select-subcontract-line-1'),
      );
      await tester.ensureVisible(subcontract);
      await tester.pump();
      await tester.tap(subcontract);
      await tester.pump();
      expect(tester.widget<Checkbox>(subcontract).value, isTrue);

      final buyNotify = find.text('通知采购（1）');
      await tester.ensureVisible(buyNotify);
      await tester.pump();
      await tester.tap(buyNotify);
      await tester.pumpAndSettle();
      final request = harness.requests.singleWhere(
        (request) => request.path.endsWith('/notify'),
      );
      expect(request.data, {
        'version': 3,
        'fingerprint': 'a' * 64,
        'idempotencyKey': isA<String>(),
        'target': 'BUY',
        'actionGroupKeys': ['buy-action-2'],
      });
      expect(tester.widget<Checkbox>(header).value, isFalse);
      expect(tester.widget<Checkbox>(subcontract).value, isTrue);
    },
  );

  testWidgets(
    'MAKE tree preserves DFS order without merging repeated material paths',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _makeTreeAnalysisJson(),
      );

      final tree = find.byKey(const Key('material-bom-tree'));
      await tester.scrollUntilVisible(
        tree,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(const ValueKey('material-bom-product-product-line-1')),
        findsOneWidget,
      );
      expect(find.text('装配'), findsNothing);
      expect(find.text('发货参考'), findsNothing);
      expect(find.textContaining('涉及 2 条路径'), findsNothing);
      expect(
        find.byKey(const ValueKey('material-bom-node-node-make-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-bom-node-node-make-2')),
        findsOneWidget,
      );
      // DFS：父件 node-make-1 行在子件 node-buy-child 行之上。
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('material-bom-node-node-make-1')),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('material-bom-node-node-buy-child')),
              )
              .dy,
        ),
      );
      // depth>1 缺料件（外箱依赖，层级 2）也可直接操作：带勾选框。
      final buyChildRow = find.byKey(
        const ValueKey('material-bom-node-node-buy-child'),
      );
      expect(
        find.descendant(of: buyChildRow, matching: find.byType(Checkbox)),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('material-node-details-toggle-make-path-1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('装配'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('material-node-details-toggle-buy-child')),
      );
      await tester.pumpAndSettle();
      expect(find.text('发货参考'), findsOneWidget);
    },
  );

  testWidgets(
    'unified tree depth>1 shortage node is actionable (checkbox and route)',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _makeTreeAnalysisJson(),
      );

      final depNode = find.byKey(
        const ValueKey('material-bom-node-node-buy-child'),
      );
      await tester.scrollUntilVisible(
        depNode,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      // depth>1 的缺料件同样可操作：可勾选、可确认路线（按类型采购/委外/自制）。
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(of: depNode, matching: find.byType(Checkbox)),
            )
            .onChanged,
        isNotNull,
      );
      await tester.tap(
        find.byKey(const ValueKey('material-node-details-toggle-buy-child')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<MaterialSupplyRoute>>(
              find.descendant(
                of: depNode,
                matching: find.byType(
                  DropdownButtonFormField<MaterialSupplyRoute>,
                ),
              ),
            )
            .onChanged,
        isNotNull,
      );
    },
  );

  testWidgets(
    'MAKE lowerLevelPending explains the gate and cannot create a task',
    (tester) async {
      final json = _makeTreeAnalysisJson();
      final material =
          (json['flatMaterials'] as List<dynamic>).first
              as Map<String, dynamic>;
      material['lowerLevelPending'] = true;
      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: json,
      );

      final makeRow = find.byKey(
        const ValueKey('material-bom-node-node-make-1'),
      );
      await tester.scrollUntilVisible(
        makeRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: makeRow, matching: find.textContaining('待齐套')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: makeRow,
          matching: find.byKey(
            const ValueKey('material-node-action-make-path-1'),
          ),
        ),
        findsNothing,
      );
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(of: makeRow, matching: find.byType(Checkbox)),
            )
            .onChanged,
        isNull,
      );
    },
  );

  testWidgets(
    'MAKE arrange production creates child task then opens its plan wizard',
    (tester) async {
      final initial = _makeTreeAnalysisJson()
        ..['allowedActions'] = const ['NOTIFY_SUPPLY', 'GENERATE_PLAN'];
      final notified = _makeReadyChildAnalysisJson();
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisNotify,
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: initial,
        responseOverride: (request) =>
            request.path.endsWith('/notify') ? notified : null,
      );

      final makeRow = find.byKey(
        const ValueKey('material-bom-node-node-make-1'),
      );
      await tester.scrollUntilVisible(
        makeRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      final arrange = find.descendant(
        of: makeRow,
        matching: find.byKey(
          const ValueKey('material-node-action-make-path-1'),
        ),
      );
      expect(
        find.descendant(of: arrange, matching: find.text('安排生产')),
        findsOneWidget,
      );
      await tester.tap(arrange);
      await tester.pumpAndSettle();

      final notify = harness.requests.singleWhere(
        (request) => request.path.endsWith('/notify'),
      );
      expect(notify.data, {
        'version': 3,
        'fingerprint': 'a' * 64,
        'idempotencyKey': isA<String>(),
        'target': 'MAKE',
        'actionGroupKeys': ['make-action-1'],
      });
      expect(find.text('填写生产计划单'), findsWidgets);
      expect(
        find.byKey(
          const ValueKey('production-plan-wizard-qty-make-child-ready-1'),
        ),
        findsOneWidget,
      );
      expect(
        find.byType(ProductionMaterialAnalysisPage, skipOffstage: false),
        findsOneWidget,
      );

      // Cancelling the form pops only the wizard. The created child task stays
      // on the refreshed analysis for another planner to continue later.
      await tester.tap(find.byTooltip('返回物料分析'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('material-analysis-results')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('material-analysis-product-make-child-ready-1'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('待安排生产'), findsWidgets);
      expect(
        harness.requests.where(
          (request) =>
              request.path.endsWith('/plan-preview') ||
              request.path.endsWith('/generate-plan'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets('MAKE row shows server execution status and latest plan link', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(1400, 1000),
      permissions: const {
        Perm.productionMaterialAnalysisManage,
        Perm.productionMaterialAnalysisNotify,
      },
      analysisJson: _makeStatusAnalysisJson(
        childSubmitted: 5,
        planExecutionStatus: 'IN_PROGRESS',
        latestPlanId: 'plan-make-1',
        latestPlanNo: 'PP-MAKE-001',
      ),
    );
    final makeRow = find.byKey(
      const ValueKey('material-bom-node-node-make-short-1'),
    );
    await tester.scrollUntilVisible(
      makeRow,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.descendant(of: makeRow, matching: find.text('生产中')),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: makeRow,
        matching: find.byKey(const ValueKey('material-view-plan-make-short-1')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: makeRow, matching: find.text('PP-MAKE-001')),
      findsOneWidget,
    );
  });

  testWidgets(
    'selected product uses wizard fields, submits only for approval and resets next batch',
    (tester) async {
      final firstRound = _analysisJson(const ['PLAN_PREVIEW', 'GENERATE_PLAN']);
      final firstRoundProducts = firstRound['products']! as List<dynamic>;
      (firstRoundProducts.first as Map<String, dynamic>)
        ..['readyStartQty'] = 6
        ..['readyFinishQty'] = 4
        ..['readyShipQty'] = 2;
      final secondRound = _analysisJson(const [
        'PLAN_PREVIEW',
        'GENERATE_PLAN',
      ]);
      final products = secondRound['products']! as List<dynamic>;
      (products.first as Map<String, dynamic>)
        ..['readyNowQty'] = 1
        ..['readyFinishQty'] = 1;
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: firstRound,
        billDate: '2026-08-09',
        deliveryDate: '2026-08-12',
        departmentId: 'workshop-1',
        workshopName: '装配一车间',
        workerId: 'worker-1',
        responseOverride: (request) {
          if (request.path.endsWith('/plan-preview')) {
            return {
              'analysisId': 'analysis-1',
              'version': 3,
              'fingerprint': 'a' * 64,
              'previewFingerprint': 'c' * 64,
              'warehouseId': 'warehouse-1',
              'allReady': true,
              'allowedActions': ['GENERATE_PLAN'],
              'items': [
                {
                  'analysisLineId': 'product-line-1',
                  'requestedQty': 10,
                  'readyNowQty': 4,
                  'selectedQty': 3,
                  'canGenerate': true,
                },
              ],
            };
          }
          if (request.path.endsWith('/generate-plan')) {
            return {
              'analysis': secondRound,
              'plans': [
                {'planId': 'plan-1', 'planNo': 'PP-20260809-001'},
              ],
            };
          }
          return null;
        },
      );

      final firstProductCard = find.byKey(
        const ValueKey('material-analysis-product-product-line-1'),
      );
      // The headline leads with the authoritative max-producible qty
      // (readyNowQty = 4); the misleading "可开工" wording is gone.
      expect(
        find.descendant(of: firstProductCard, matching: find.text('最多可生产 4 个')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: firstProductCard, matching: find.text('齐套 40%')),
        findsOneWidget,
      );
      // Secondary stage quantities and the batch input stay collapsed until
      // the planner selects this product.
      expect(
        find.descendant(
          of: firstProductCard,
          matching: find.textContaining('开工段就绪 6'),
        ),
        findsNothing,
      );
      expect(find.byKey(const Key('batch-qty-product-line-1')), findsNothing);
      await tester.tap(
        find.byKey(
          const ValueKey('material-analysis-product-select-product-line-1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: firstProductCard,
          matching: find.textContaining('开工段就绪 6'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: firstProductCard,
          matching: find.textContaining('含包装可发 2'),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('batch-qty-product-line-1')),
            )
            .controller
            ?.text,
        '',
      );
      expect(
        find.descendant(of: firstProductCard, matching: find.text('最多 4 个')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('batch-qty-product-line-1')),
        '3',
      );
      expect(find.text('生成总装计划（1）'), findsOneWidget);
      await tester.tap(find.text('生成总装计划（1）'));
      await tester.pumpAndSettle();
      expect(find.text('生产计划单'), findsWidgets);

      await tester.tap(find.text('汇总确认'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('production-plan-wizard-submit')));
      await tester.pumpAndSettle();

      expect(find.text('生产计划已生成'), findsOneWidget);
      expect(find.textContaining('PP-20260809-001'), findsOneWidget);
      expect(find.text('留在物料分析'), findsOneWidget);
      expect(find.text('查看计划'), findsOneWidget);
      await tester.tap(find.text('留在物料分析'));
      await tester.pumpAndSettle();

      final generate = harness.requests.singleWhere(
        (request) => request.path.endsWith('/generate-plan'),
      );
      final body = generate.data! as Map<String, dynamic>;
      expect(body['approveNow'], isFalse);
      expect(body['departmentId'], 'workshop-1');
      expect(body['workerId'], 'worker-1');
      expect(body['items'], [
        {
          'analysisLineId': 'product-line-1',
          'qty': 3.0,
          'billDate': '2026-08-09',
          'deliveryDate': '2026-08-12',
          'departmentId': 'workshop-1',
          'workshopName': '装配一车间',
          'workerId': 'worker-1',
        },
      ]);
      // A server refresh clears selection and collapses plan-only fields.
      expect(find.byKey(const Key('batch-qty-product-line-1')), findsNothing);
      expect(find.byKey(const Key('material-analysis-generate')), findsNothing);
      expect(
        find.byKey(const Key('material-analysis-results')),
        findsOneWidget,
      );
    },
  );
}

Future<void> _chooseRoute(WidgetTester tester, String label) async {
  var routeFinder = find.byType(DropdownButtonFormField<MaterialSupplyRoute>);
  if (routeFinder.evaluate().isEmpty) {
    final details = find.byKey(
      const ValueKey('material-node-details-toggle-material-path-1'),
    );
    await tester.scrollUntilVisible(
      details,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(details);
    await tester.pumpAndSettle();
    routeFinder = find.byType(DropdownButtonFormField<MaterialSupplyRoute>);
  }
  await tester.ensureVisible(routeFinder);
  await tester.pumpAndSettle();
  await tester.tap(routeFinder);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<_Harness> _pumpPage(
  WidgetTester tester, {
  required Size size,
  required Set<String> permissions,
  List<String> allowedActions = const ['PLAN_PREVIEW', 'GENERATE_PLAN'],
  bool seeded = true,
  String? analysisId,
  List<MaterialAnalysisSourceInput>? sources,
  Map<String, dynamic>? analysisJson,
  Map<String, dynamic>? Function(RequestOptions request)? responseOverride,
  String? billDate,
  String? deliveryDate,
  String? departmentId,
  String? workshopName,
  String? workerId,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final requests = <RequestOptions>[];
  final api = _api(
    requests,
    allowedActions,
    analysisJson: analysisJson,
    responseOverride: responseOverride,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        departmentPickerTreeProvider.overrideWith(
          (ref) async => const <DepartmentNode>[],
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp(
        home: ProductionMaterialAnalysisPage(
          seed: ProductionMaterialAnalysisSeed(
            analysisId: analysisId,
            warehouseId: 'warehouse-1',
            billDate: billDate,
            deliveryDate: deliveryDate,
            departmentId: departmentId,
            workshopName: workshopName,
            workerId: workerId,
            sources:
                sources ??
                (seeded
                    ? const [
                        MaterialAnalysisSourceInput(
                          salesOrderItemId: 'sales-line-1',
                          requestedQty: 10,
                        ),
                      ]
                    : const []),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return _Harness(requests);
}

ApiClient _api(
  List<RequestOptions> requests,
  List<String> allowedActions, {
  Map<String, dynamic>? analysisJson,
  Map<String, dynamic>? Function(RequestOptions request)? responseOverride,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        final custom = responseOverride?.call(request);
        final data =
            custom ??
            switch (request.path) {
              '/master/warehouses/dict' => [
                {'id': 'warehouse-1', 'name': '主仓'},
              ],
              '/production/material-analyses/preview' =>
                analysisJson ?? _analysisJson(allowedActions),
              '/production/material-analyses/analysis-1' =>
                analysisJson ?? _analysisJson(allowedActions),
              '/production/material-analyses/sales-candidates' => {
                'items': <Map<String, dynamic>>[],
                'page': 1,
                'size': 20,
                'total': 0,
                'totalPages': 1,
              },
              '/production/material-analyses/analysis-1/routes' =>
                _analysisJson(allowedActions, routeConfirmed: true),
              '/production/material-analyses/analysis-1/notify' =>
                analysisJson ?? _analysisJson(allowedActions),
              '/production/material-analyses/analysis-1/allocation-priorities' =>
                _analysisJson(allowedActions),
              _ => <Map<String, dynamic>>[],
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
  return ApiClient(dio);
}

Map<String, dynamic> _analysisJson(
  List<String> allowedActions, {
  bool routeConfirmed = false,
}) => {
  'analysisId': 'analysis-1',
  'status': 'ANALYZED',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse-1',
  'analyzedAt': '2026-08-08T10:00:00Z',
  'allowedActions': allowedActions,
  'products': [
    {
      'analysisLineId': 'product-line-1',
      'salesOrderItemId': 'sales-line-1',
      'orderNo': 'SO-1',
      'goodsCode': 'P-1',
      'goodsName': '测试产品',
      'requestedQty': 10,
      'remainingQty': 10,
      'readyNowQty': 4,
      'readyByDateQty': 8,
      'readinessRatio': 0.4,
      'productionBomPolicy': 'DIRECT_MAKE',
      'missingBom': false,
      'bomOverrideRequired': false,
      'hasActiveBom': false,
      'allocationPriority': 1,
    },
    {
      'analysisLineId': 'product-line-2',
      'sourceType': 'STOCK',
      'goodsCode': 'P-2',
      'goodsName': '第二测试产品',
      'requestedQty': 6,
      'remainingQty': 6,
      'readyNowQty': 2,
      'readyByDateQty': 4,
      'readinessRatio': 0.3333,
      'productionBomPolicy': 'DIRECT_MAKE',
      'missingBom': false,
      'bomOverrideRequired': false,
      'hasActiveBom': false,
      'allocationPriority': 2,
    },
  ],
  'flatMaterials': [
    _materialJson(
      id: 'material-path-1',
      level: 2,
      path: ['测试产品', '组件 A', '共享紧固件'],
      routeConfirmed: routeConfirmed,
    ),
    _materialJson(
      id: 'material-path-2',
      level: 3,
      path: ['测试产品', '组件 B', '下层件', '共享紧固件'],
      routeConfirmed: routeConfirmed,
    ),
    {
      'materialLineId': 'dependency-path-1',
      'analysisLineId': 'product-line-1',
      'nodeKey': 'dependency-node-1',
      'actionGroupKey': 'dependency-action-1',
      'materialKey': 'dependency-goods||unit-1',
      'goodsId': 'dependency-goods',
      'goodsCode': 'D-1',
      'goodsName': '下层依赖件',
      'unitName': '个',
      'level': 3,
      'path': ['测试产品', '自制组件', '下层依赖件'],
      'requiredQty': 20,
      'allocatedAvailableQty': 4,
      'availableQty': 7,
      'shortageQty': 16,
      'sourceSuggestion': 'BUY',
      'routeConfirmed': false,
      'actionable': false,
    },
  ],
  'warehouses': [
    {'warehouseId': 'warehouse-1', 'warehouseName': '主仓'},
  ],
};

Map<String, dynamic> _buySelectionAnalysisJson() {
  final json = _analysisJson(const ['NOTIFY_SUPPLY']);
  json['flatMaterials'] = [
    _routeMaterial(
      id: 'buy-line-1',
      nodeKey: 'buy-node-1',
      actionGroupKey: 'buy-action-1',
      goodsCode: 'BUY-1',
      goodsName: '采购件一',
      route: 'BUY',
      controlStage: 'START',
    ),
    _routeMaterial(
      id: 'buy-line-2',
      nodeKey: 'buy-node-2',
      actionGroupKey: 'buy-action-2',
      goodsCode: 'BUY-2',
      goodsName: '采购件二',
      route: 'BUY',
      controlStage: 'FINISH',
    ),
    _routeMaterial(
      id: 'subcontract-line-1',
      nodeKey: 'subcontract-node-1',
      actionGroupKey: 'subcontract-action-1',
      goodsCode: 'SUB-1',
      goodsName: '委外件一',
      route: 'SUBCONTRACT',
      controlStage: 'ASSEMBLY',
    ),
  ];
  return json;
}

Map<String, dynamic> _makeTreeAnalysisJson() {
  final json = _analysisJson(const ['CONFIRM_ROUTES', 'NOTIFY_SUPPLY']);
  json['flatMaterials'] = [
    _routeMaterial(
      id: 'make-path-1',
      nodeKey: 'node-make-1',
      actionGroupKey: 'make-action-1',
      goodsCode: 'MAKE-A',
      goodsName: '自制组件 A',
      route: 'MAKE',
      controlStage: 'ASSEMBLY',
    ),
    {
      ..._routeMaterial(
        id: 'buy-child',
        nodeKey: 'node-buy-child',
        actionGroupKey: 'buy-child-action',
        goodsCode: 'BUY-CHILD',
        goodsName: '外箱依赖',
        route: 'BUY',
        controlStage: 'SHIP',
      ),
      'parentNodeKey': 'node-make-1',
      'level': 2,
    },
    _routeMaterial(
      id: 'make-path-2',
      nodeKey: 'node-make-2',
      actionGroupKey: 'make-action-2',
      goodsCode: 'MAKE-B',
      goodsName: '自制组件 A（另一 BOM 路径）',
      route: 'MAKE',
      controlStage: 'ASSEMBLY',
    ),
  ];
  return json;
}

Map<String, dynamic> _makeReadyChildAnalysisJson() {
  final json = _makeTreeAnalysisJson()
    ..['allowedActions'] = const ['NOTIFY_SUPPLY', 'GENERATE_PLAN'];
  final materials = json['flatMaterials']! as List<dynamic>;
  final makeMaterial = materials.cast<Map<String, dynamic>>().singleWhere(
    (material) => material['materialLineId'] == 'make-path-1',
  );
  makeMaterial['notifiedTargets'] = [
    {
      'target': 'MAKE',
      'documentType': 'PREPLAN_MAKE_TASK',
      'documentId': 'make-child-ready-1',
      'status': 'CREATED',
    },
  ];
  (json['products']! as List<dynamic>).add({
    'analysisLineId': 'make-child-ready-1',
    'sourceType': 'MAKE_COMPONENT',
    'parentAnalysisLineId': 'product-line-1',
    'parentGoodsName': '测试产品',
    'goodsId': 'goods-make-path-1',
    'goodsCode': 'MAKE-A',
    'goodsName': '自制组件 A（备料任务）',
    'unitName': '个',
    'requestedQty': 8,
    'submittedQty': 0,
    'approvedQty': 0,
    'remainingQty': 8,
    'readyNowQty': 8,
    'readinessRatio': 1,
    'productionBomPolicy': 'DIRECT_MAKE',
    'missingBom': false,
    'bomOverrideRequired': false,
    'hasActiveBom': false,
    'allocationPriority': 3,
  });
  return json;
}

/// 一个已通知自制的 depth-1 节点 + 关联的 MAKE_COMPONENT 子产品，用于验证
/// 待生产/生产中/已完工 状态推导（子产品 submitted/approved 驱动）。
Map<String, dynamic> _makeStatusAnalysisJson({
  double childSubmitted = 0,
  double childApproved = 0,
  double shortage = 8,
  String? planExecutionStatus,
  String? latestPlanId,
  String? latestPlanNo,
}) {
  final json = _analysisJson(const ['PLAN_PREVIEW', 'GENERATE_PLAN']);
  json['flatMaterials'] = [
    {
      'materialLineId': 'make-short-1',
      'analysisLineId': 'product-line-1',
      'nodeKey': 'node-make-short-1',
      'actionGroupKey': 'make-short-action',
      'materialKey': 'MAKE-SHORT||unit-1',
      'goodsId': 'goods-make-short',
      'goodsCode': 'MAKE-SHORT',
      'goodsName': '自制短缺件',
      'unitName': '个',
      'level': 1,
      'path': ['测试产品', '自制短缺件'],
      'requiredQty': 10,
      'allocatedAvailableQty': 2,
      'availableQty': 2,
      'shortageQty': shortage,
      'sourceSuggestion': 'MAKE',
      'sourceConfirmed': 'MAKE',
      'routeConfirmed': true,
      'controlStage': 'ASSEMBLY',
      'hardGate': true,
      'actionable': true,
      'notifiedTargets': [
        {
          'target': 'MAKE',
          'documentType': 'PREPLAN_MAKE_TASK',
          'documentId': 'child-line-1',
          'status': 'CREATED',
        },
      ],
    },
  ];
  json['products'] = [
    ...(json['products'] as List<dynamic>),
    {
      'analysisLineId': 'child-line-1',
      'sourceType': 'MAKE_COMPONENT',
      'parentAnalysisLineId': 'product-line-1',
      'parentGoodsName': '自制短缺件',
      'goodsId': 'goods-make-short',
      'goodsCode': 'MAKE-SHORT',
      'goodsName': '自制短缺件（自制备料）',
      'requestedQty': 8,
      'submittedQty': childSubmitted,
      'approvedQty': childApproved,
      'remainingQty': 8 - childApproved,
      'readyNowQty': 0,
      'planExecutionStatus': ?planExecutionStatus,
      'latestPlanId': ?latestPlanId,
      'latestPlanNo': ?latestPlanNo,
    },
  ];
  return json;
}

Map<String, dynamic> _routeMaterial({
  required String id,
  required String nodeKey,
  required String actionGroupKey,
  required String goodsCode,
  required String goodsName,
  required String route,
  required String controlStage,
}) => {
  'materialLineId': id,
  'analysisLineId': 'product-line-1',
  'nodeKey': nodeKey,
  'actionGroupKey': actionGroupKey,
  'materialKey': '$goodsCode||unit-1',
  'goodsId': 'goods-$id',
  'goodsCode': goodsCode,
  'goodsName': goodsName,
  'unitName': '个',
  'level': 1,
  'path': ['测试产品', goodsName],
  'requiredQty': 10,
  'allocatedAvailableQty': 2,
  'availableQty': 2,
  'shortageQty': 8,
  'sourceSuggestion': route,
  'sourceConfirmed': route,
  'routeConfirmed': true,
  'controlStage': controlStage,
  'hardGate': true,
  'actionable': true,
};

Map<String, dynamic> _materialJson({
  required String id,
  required int level,
  required List<String> path,
  required bool routeConfirmed,
}) => {
  'materialLineId': id,
  'analysisLineId': 'product-line-1',
  'nodeKey': id,
  'actionGroupKey': 'action-$id',
  'materialKey': 'goods-fastener||unit-1',
  'goodsId': 'goods-fastener',
  'goodsCode': 'M-1',
  'goodsName': '共享紧固件',
  'unitName': '个',
  'level': level,
  'path': path,
  'requiredQty': 16,
  'allocatedAvailableQty': 3,
  'availableQty': 3,
  'inboundQty': 2,
  'shortageQty': 11,
  'sourceSuggestion': 'BUY',
  'sourceConfirmed': routeConfirmed ? 'MAKE' : null,
  'routeConfirmed': routeConfirmed,
  'routeReason': routeConfirmed ? '交期紧急，改为车间自制' : null,
  'lowerLevelPending': false,
  'actionable': true,
};

class _Harness {
  const _Harness(this.requests);

  final List<RequestOptions> requests;
}
