import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/production_department_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  test(
    'material requirement ownership projection parses exact server fields',
    () {
      final delegated = ProductionMaterialAnalysisMaterial.fromJson({
        'materialLineId': 'delegated-line',
        'requiredQty': 0,
        'requirementState': 'DELEGATED_TO_MAKE_CHILD',
        'delegatedToAnalysisLineId': 'make-child-line',
        'delegatedToSourceRef': '自制备料 2026-08-30 abcd',
        'delegatedToRequestedQty': 12.5,
        'actionable': false,
      });

      expect(
        delegated.requirementState,
        MaterialRequirementState.delegatedToMakeChild,
      );
      expect(
        delegated.effectiveRequirementState,
        MaterialRequirementState.delegatedToMakeChild,
      );
      expect(delegated.delegatedToAnalysisLineId, 'make-child-line');
      expect(delegated.delegatedToSourceRef, '自制备料 2026-08-30 abcd');
      expect(delegated.delegatedToRequestedQty, 12.5);

      final subcontractPreparation =
          ProductionMaterialAnalysisMaterial.fromJson({
            'materialLineId': 'subcontract-preparation-line',
            'requiredQty': 0,
            'requirementState': 'DELEGATED_TO_SUBCONTRACT_PREPARATION',
            'subcontractHandoffFutureQty': 8.5,
            'actionable': false,
          });
      expect(
        subcontractPreparation.effectiveRequirementState,
        MaterialRequirementState.delegatedToSubcontractPreparation,
      );
      expect(subcontractPreparation.subcontractHandoffFutureQty, 8.5);

      final positiveDemand = ProductionMaterialAnalysisMaterial.fromJson({
        'materialLineId': 'active-line',
        'requiredQty': 3,
        'requirementState': 'INACTIVE_PARENT_ROUTE',
        'actionable': true,
      });
      expect(
        positiveDemand.effectiveRequirementState,
        MaterialRequirementState.active,
        reason:
            'positive server demand must remain ACTIVE even for a stale state',
      );

      final legacyZero = ProductionMaterialAnalysisMaterial.fromJson({
        'materialLineId': 'legacy-zero',
        'requiredQty': 0,
        'actionable': false,
      });
      expect(
        legacyZero.effectiveRequirementState,
        MaterialRequirementState.inactive,
        reason:
            'legacy zero demand must not be guessed as covered or delegated',
      );
    },
  );

  testWidgets('fresh analysis exposes audited manual source types', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
      },
      seeded: false,
    );

    expect(find.text('手工计划(返工 / 试制 / 样品 / 备库)'), findsOneWidget);
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

  testWidgets(
    'desktop sales candidates support row and tri-state header selection',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1400, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        seeded: false,
        responseOverride: (request) =>
            request.path.endsWith('/sales-candidates')
            ? _salesCandidatesJson()
            : null,
      );

      final table = find.byKey(const Key('material-analysis-candidate-table'));
      final checkboxes = find.descendant(
        of: table,
        matching: find.byType(Checkbox),
      );
      expect(table, findsOneWidget);
      expect(checkboxes, findsNWidgets(3));
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isFalse);

      await tester.tap(checkboxes.at(0));
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isTrue);
      expect(find.text('已选 2 个产品 · 数量已预填，只需修改例外'), findsOneWidget);
      expect(find.byKey(const Key('source-qty-sales-line-a')), findsOneWidget);
      expect(find.byKey(const Key('source-qty-sales-line-b')), findsOneWidget);

      await tester.tap(checkboxes.at(1));
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isNull);
      expect(find.text('已选 1 个产品 · 数量已预填，只需修改例外'), findsOneWidget);

      // Tri-state header follows Checkbox semantics: partial -> clear page,
      // then unchecked -> select all, then checked -> clear again.
      await tester.tap(checkboxes.at(0));
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isFalse);
      await tester.tap(checkboxes.at(0));
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isTrue);
      await tester.tap(checkboxes.at(0));
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isFalse);
      // MasterDataTableView 仍会如实显示「已选 0 项」；这里真正要守住的是
      // 页面级已选产品数量编辑区已经清空，不能用跨组件的泛化文案断言。
      expect(find.byKey(const Key('source-qty-sales-line-a')), findsNothing);
      expect(find.byKey(const Key('source-qty-sales-line-b')), findsNothing);
    },
  );

  testWidgets(
    'compact sales candidates paginate and preserve cross-page selection',
    (tester) async {
      final requestedPages = <int>[];
      await _pumpPage(
        tester,
        size: const Size(375, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        seeded: false,
        responseOverride: (request) {
          if (!request.path.endsWith('/sales-candidates')) return null;
          final page = (request.queryParameters['page'] as num?)?.toInt() ?? 1;
          requestedPages.add(page);
          return _pagedSalesCandidatesJson(page);
        },
      );

      final mobileList = find.byKey(
        const Key('material-analysis-candidate-mobile-list'),
      );
      expect(
        find.descendant(of: mobileList, matching: find.byType(ListView)),
        findsNothing,
      );
      expect(find.text('手机候选产品 A'), findsOneWidget);
      expect(find.text('上一页'), findsOneWidget);
      expect(find.text('下一页'), findsOneWidget);
      expect(find.textContaining('第 1 / 2 页'), findsOneWidget);

      final candidateCheckbox = find.descendant(
        of: mobileList,
        matching: find.byType(Checkbox),
      );
      await tester.ensureVisible(candidateCheckbox);
      await tester.tap(candidateCheckbox);
      await tester.pump();
      final editSelectedQty = find.byKey(
        const Key('material-compact-edit-selected-qty'),
      );
      expect(
        find.byKey(const Key('source-qty-mobile-sales-line-a')),
        findsNothing,
      );
      await tester.ensureVisible(editSelectedQty);
      await tester.tap(editSelectedQty);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('material-compact-selected-qty-list')),
        findsOneWidget,
      );
      final firstQty = find.byKey(const Key('source-qty-mobile-sales-line-a'));
      expect(firstQty, findsOneWidget);
      expect(tester.widget<TextField>(firstQty).controller?.text, '8');
      await tester.enterText(firstQty, '9');
      await tester.tap(find.text('数量核对完成'));
      await tester.pumpAndSettle();
      expect(firstQty, findsNothing);

      await tester.tap(find.byKey(const Key('material-candidate-next-page')));
      await tester.pumpAndSettle();
      expect(find.text('手机候选产品 B'), findsOneWidget);
      expect(find.textContaining('第 2 / 2 页'), findsOneWidget);
      expect(
        find.byKey(const Key('source-qty-mobile-sales-line-a')),
        findsNothing,
      );

      await tester.ensureVisible(candidateCheckbox);
      await tester.tap(candidateCheckbox);
      await tester.pump();
      expect(tester.widget<Checkbox>(candidateCheckbox).value, isTrue);
      expect(find.text('已选 2 个销售产品'), findsOneWidget);
      expect(
        find.byKey(const Key('source-qty-mobile-sales-line-b')),
        findsNothing,
      );

      await tester.ensureVisible(editSelectedQty);
      await tester.tap(editSelectedQty);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(firstQty).controller?.text, '9');
      expect(
        find.byKey(const Key('source-qty-mobile-sales-line-b')),
        findsOneWidget,
      );
      await tester.tap(find.text('数量核对完成'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: mobileList, matching: find.byType(ListView)),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('material-candidate-prev-page')));
      await tester.pumpAndSettle();
      expect(find.text('手机候选产品 A'), findsOneWidget);
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(of: mobileList, matching: find.byType(Checkbox)),
            )
            .value,
        isTrue,
      );
      expect(requestedPages, containsAllInOrder([1, 2, 1]));
    },
  );

  testWidgets(
    'compact read-only candidates hide selection controls and the floating CTA',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(375, 900),
        permissions: const {Perm.productionMaterialAnalysisView},
        seeded: false,
        responseOverride: (request) =>
            request.path.endsWith('/sales-candidates')
            ? _salesCandidatesJson()
            : null,
      );

      final mobileList = find.byKey(
        const Key('material-analysis-candidate-mobile-list'),
      );
      expect(mobileList, findsOneWidget);
      expect(
        find.descendant(of: mobileList, matching: find.byType(Checkbox)),
        findsNothing,
      );
      expect(find.byKey(const Key('material-analysis-start')), findsNothing);
    },
  );

  testWidgets('seeded manual analysis sends the stable demand reference', (
    tester,
  ) async {
    final harness = await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
      },
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
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        allowedActions: const ['REFRESH'],
        analysisJson: _analysisJson(const ['REFRESH']),
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
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
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
    'refresh CAS conflict loads the latest server analysis instead of keeping stale zero',
    (tester) async {
      var detailReads = 0;
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        allowedActions: const ['REFRESH'],
        analysisId: 'analysis-1',
        errorOverride: (request) =>
            request.method == 'POST' &&
                request.path == '/production/material-analyses/preview'
            ? _materialAnalysisConflict(request)
            : null,
        responseOverride: (request) {
          if (request.method != 'GET' ||
              request.path != '/production/material-analyses/analysis-1') {
            return null;
          }
          detailReads++;
          final json = _analysisJson(const ['REFRESH']);
          final firstProduct =
              (json['products']! as List<dynamic>).first
                  as Map<String, dynamic>;
          firstProduct['readyNowQty'] = detailReads == 1 ? 0 : 7;
          firstProduct['readinessRatio'] = detailReads == 1 ? 0 : 0.7;
          json['version'] = detailReads == 1 ? 3 : 4;
          json['fingerprint'] = (detailReads == 1 ? 'a' : 'b') * 64;
          return json;
        },
      );

      expect(detailReads, 2);
      expect(find.text('最多可生产 7 个'), findsOneWidget);
      await tester.drag(
        find
            .descendant(
              of: find.byKey(const Key('material-analysis-results')),
              matching: find.byType(Scrollable),
            )
            .first,
        const Offset(0, 1000),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('刷新物料分析未自动重试'), findsOneWidget);
      expect(find.textContaining('已加载服务端最新物料分析'), findsOneWidget);
      expect(
        harness.requests.where(
          (request) =>
              request.method == 'GET' &&
              request.path == '/production/material-analyses/analysis-1',
        ),
        hasLength(2),
      );
    },
  );

  testWidgets(
    'CAS recovery keeps valid unsaved route drafts and tells the planner',
    (tester) async {
      var previewCalls = 0;
      var detailReads = 0;
      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisRoute,
        },
        allowedActions: const ['REFRESH', 'CONFIRM_ROUTES'],
        analysisJson: _analysisJson(const ['REFRESH', 'CONFIRM_ROUTES']),
        analysisId: 'analysis-1',
        errorOverride: (request) {
          if (request.path == '/production/material-analyses/preview') {
            previewCalls++;
            return previewCalls == 2
                ? _materialAnalysisConflict(request)
                : null;
          }
          if (request.path.endsWith('/routes')) {
            return DioException(
              requestOptions: request,
              type: DioExceptionType.receiveTimeout,
              message: '保留未保存路线草稿',
            );
          }
          return null;
        },
        responseOverride: (request) {
          if (request.method != 'GET' ||
              request.path != '/production/material-analyses/analysis-1') {
            return null;
          }
          detailReads++;
          final json = _analysisJson(const ['REFRESH', 'CONFIRM_ROUTES']);
          json['version'] = detailReads == 1 ? 3 : 4;
          json['fingerprint'] = (detailReads == 1 ? 'a' : 'b') * 64;
          return json;
        },
      );

      await tester.tap(find.text('采纳建议路线(2)'));
      await tester.pumpAndSettle();
      expect(find.text('确认路线(2)'), findsOneWidget);

      await tester.tap(find.byTooltip('按最新库存刷新分析'));
      await tester.pumpAndSettle();

      expect(detailReads, 2);
      expect(find.text('确认路线(2)'), findsOneWidget);
      await tester.drag(
        find
            .descendant(
              of: find.byKey(const Key('material-analysis-results')),
              matching: find.byType(Scrollable),
            )
            .first,
        const Offset(0, 1000),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('刷新物料分析未自动重试'), findsOneWidget);
      expect(find.textContaining('已保留 2 条未保存路线草稿'), findsOneWidget);
    },
  );

  testWidgets(
    'idle persisted analysis polls latest read-only snapshot after 45 seconds',
    (tester) async {
      var detailReads = 0;
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        allowedActions: const ['VIEW'],
        analysisId: 'analysis-1',
        seeded: false,
        responseOverride: (request) {
          if (request.method != 'GET' ||
              request.path != '/production/material-analyses/analysis-1') {
            return null;
          }
          detailReads++;
          final json = _analysisJson(const ['VIEW']);
          final firstProduct =
              (json['products']! as List<dynamic>).first
                  as Map<String, dynamic>;
          firstProduct['readyNowQty'] = detailReads == 1 ? 0 : 7;
          firstProduct['readinessRatio'] = detailReads == 1 ? 0 : 0.7;
          json['version'] = detailReads;
          json['fingerprint'] = (detailReads == 1 ? 'a' : 'b') * 64;
          return json;
        },
      );

      expect(detailReads, 1);
      expect(find.text('暂不可生产'), findsOneWidget);
      final blocker = find.byKey(
        const ValueKey('material-analysis-product-blocker-product-line-1'),
      );
      expect(blocker, findsOneWidget);
      final blockerText = tester.widget<Text>(blocker);
      expect(
        blockerText.style?.color,
        Theme.of(tester.element(blocker)).colorScheme.onErrorContainer,
      );
      final blockedGate = find.byKey(
        const ValueKey('material-analysis-task-state-product-product-line-1'),
      );
      expect(blockedGate, findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('material-analysis-product-select-product-line-1'),
        ),
        findsNothing,
      );

      await tester.pump(const Duration(seconds: 45));
      await tester.pumpAndSettle();

      expect(detailReads, 2);
      expect(find.text('最多可生产 7 个'), findsOneWidget);
      expect(blocker, findsNothing);
      expect(blockedGate, findsNothing);
      expect(
        find.byKey(
          const ValueKey('material-analysis-product-select-product-line-1'),
        ),
        findsOneWidget,
      );
      expect(
        harness.requests.where(
          (request) =>
              request.method == 'POST' &&
              request.path == '/production/material-analyses/preview',
        ),
        isEmpty,
      );
    },
  );

  testWidgets(
    'fully transferred product shows execution stage and plan action instead of shortage',
    (tester) async {
      final analysis = _analysisJson(const ['VIEW']);
      final product =
          (analysis['products']! as List<dynamic>).first
              as Map<String, dynamic>;
      product
        ..['requestedQty'] = 10
        ..['submittedQty'] = 10
        ..['approvedQty'] = 0
        ..['remainingQty'] = 0
        ..['readyNowQty'] = 0
        ..['readinessRatio'] = 1
        ..['planExecutionStatus'] = 'IN_PROGRESS'
        ..['latestPlanId'] = 'plan-running-1'
        ..['latestPlanNo'] = 'PP-20260828-001'
        ..['planExecutionPlannedQty'] = 10
        ..['planExecutionInboundQty'] = 5
        ..['planExecutionProgressRatio'] = 0.5;

      await _pumpPage(
        tester,
        size: const Size(375, 900),
        permissions: const {
          Perm.productionMaterialAnalysisView,
          Perm.productionPlanView,
        },
        allowedActions: const ['VIEW'],
        analysisId: 'analysis-1',
        seeded: false,
        analysisJson: analysis,
        theme: ThemeData.dark(),
        textScale: 1.3,
      );

      expect(find.text('生产执行中 50%'), findsOneWidget);
      final statusPanel = find.byKey(
        const ValueKey('material-analysis-product-execution-product-line-1'),
      );
      final progressFill = find.byKey(
        const ValueKey(
          'material-analysis-product-execution-fill-product-line-1',
        ),
      );
      expect(statusPanel, findsOneWidget);
      expect(progressFill, findsOneWidget);
      expect(
        tester.getSize(progressFill).width,
        closeTo(tester.getSize(statusPanel).width * 0.5, 0.5),
      );
      final panelTheme = Theme.of(tester.element(statusPanel));
      expect(
        tester.widget<ColoredBox>(progressFill).color,
        panelTheme.colorScheme.primary,
      );
      expect(find.text('进入生产计划查看剩余可报、品质判定和仓库待点收进度'), findsNothing);
      expect(find.text('暂不可生产'), findsNothing);
      expect(find.text('齐套 100%'), findsNothing);
      expect(
        find.byKey(
          const ValueKey('material-analysis-product-select-product-line-1'),
        ),
        findsNothing,
      );
      final action = find.byKey(
        const ValueKey('material-analysis-product-plan-product-line-1'),
      );
      expect(action, findsOneWidget);
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('legacy execution response does not invent zero percent', (
    tester,
  ) async {
    final analysis = _analysisJson(const ['VIEW']);
    final product =
        (analysis['products']! as List<dynamic>).first as Map<String, dynamic>;
    product
      ..['requestedQty'] = 10
      ..['submittedQty'] = 10
      ..['remainingQty'] = 0
      ..['planExecutionStatus'] = 'IN_PROGRESS'
      ..['latestPlanId'] = 'legacy-plan';

    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {Perm.productionMaterialAnalysisView},
      allowedActions: const ['VIEW'],
      analysisId: 'analysis-1',
      seeded: false,
      analysisJson: analysis,
    );

    final statusPanel = find.byKey(
      const ValueKey('material-analysis-product-execution-product-line-1'),
    );
    expect(
      find.descendant(of: statusPanel, matching: find.text('生产执行中 · 执行进度待回传')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey(
          'material-analysis-product-execution-fill-product-line-1',
        ),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'return refresh applies dynamic plan projection with unchanged CAS header',
    (tester) async {
      var detailReads = 0;
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisView,
          Perm.productionPlanView,
        },
        allowedActions: const ['VIEW'],
        analysisId: 'analysis-1',
        seeded: false,
        responseOverride: (request) {
          if (request.method != 'GET' ||
              request.path != '/production/material-analyses/analysis-1') {
            return null;
          }
          detailReads++;
          final json = _analysisJson(const ['VIEW']);
          final product =
              (json['products']! as List<dynamic>).first
                  as Map<String, dynamic>;
          product
            ..['requestedQty'] = 10
            ..['submittedQty'] = 10
            ..['remainingQty'] = 0
            ..['readyNowQty'] = 0
            ..['readinessRatio'] = 1
            ..['planExecutionStatus'] = 'IN_PROGRESS'
            ..['latestPlanId'] = 'plan-running-1'
            ..['latestPlanNo'] = 'PP-20260828-001'
            ..['planExecutionPlannedQty'] = 10
            ..['planExecutionInboundQty'] = switch (detailReads) {
              1 => 1,
              2 => 3,
              _ => 10,
            }
            ..['planExecutionProgressRatio'] = switch (detailReads) {
              1 => 0.1,
              2 => 0.3,
              _ => 1.0,
            };
          json['version'] = 7;
          json['fingerprint'] = 'f' * 64;
          return json;
        },
      );

      final statusPanel = find.byKey(
        const ValueKey('material-analysis-product-execution-product-line-1'),
      );
      expect(
        find.descendant(of: statusPanel, matching: find.text('生产执行中 10%')),
        findsOneWidget,
      );
      final progressFill = find.byKey(
        const ValueKey(
          'material-analysis-product-execution-fill-product-line-1',
        ),
      );
      expect(
        tester.getSize(progressFill).width / tester.getSize(statusPanel).width,
        closeTo(0.1, 0.01),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductionMaterialAnalysisPage)),
      );
      container.read(pageResumeProvider.notifier).state = (
        location: '/warehouse/DRAW/draw-1',
        tick: 1,
      );
      await tester.pump();
      container.read(pageResumeProvider.notifier).state = (
        location: '/production/material-analysis',
        tick: 2,
      );
      await tester.pumpAndSettle();

      expect(detailReads, 2);
      expect(
        find.descendant(of: statusPanel, matching: find.text('生产执行中 30%')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: statusPanel, matching: find.text('生产执行中 10%')),
        findsNothing,
      );
      expect(
        tester.getSize(progressFill).width / tester.getSize(statusPanel).width,
        closeTo(0.3, 0.01),
      );

      container.read(pageResumeProvider.notifier).state = (
        location: '/warehouse/DRAW/draw-1',
        tick: 3,
      );
      await tester.pump();
      container.read(pageResumeProvider.notifier).state = (
        location: '/production/material-analysis',
        tick: 4,
      );
      await tester.pumpAndSettle();

      expect(detailReads, 3);
      expect(
        find.descendant(of: statusPanel, matching: find.text('生产执行中 100%')),
        findsOneWidget,
      );
      expect(
        tester.getSize(progressFill).width / tester.getSize(statusPanel).width,
        closeTo(1, 0.01),
      );
    },
  );

  testWidgets(
    'analysis poll skips unsaved route editing and timer cancels on dispose',
    (tester) async {
      var detailReads = 0;
      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {Perm.productionMaterialAnalysisRoute},
        allowedActions: const ['CONFIRM_ROUTES'],
        analysisJson: _analysisJson(const ['CONFIRM_ROUTES']),
        analysisId: 'analysis-1',
        seeded: false,
        errorOverride: (request) => request.path.endsWith('/routes')
            ? DioException(
                requestOptions: request,
                type: DioExceptionType.receiveTimeout,
                message: '保留未保存路线草稿',
              )
            : null,
        responseOverride: (request) {
          if (request.method == 'GET' &&
              request.path == '/production/material-analyses/analysis-1') {
            detailReads++;
          }
          return null;
        },
      );

      await tester.tap(find.text('采纳建议路线(2)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('确认路线(', skipOffstage: false), findsOneWidget);

      await tester.pump(const Duration(seconds: 45));
      await tester.pumpAndSettle();
      expect(detailReads, 1);
      expect(find.textContaining('确认路线(', skipOffstage: false), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 45));
      expect(detailReads, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'product without child materials is shown as direct make instead of a BOM error',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final analysis = _analysisJson(const ['VIEW']);
      final products = (analysis['products']! as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final product = products.first;
      final materialBackedProduct = products.last;
      product
        ..['readyNowQty'] = 10
        ..['readyByDateQty'] = 10
        ..['readinessRatio'] = 1
        ..['hasProductionMaterialChildren'] = false;
      materialBackedProduct
        ..['readyNowQty'] = 6
        ..['readyByDateQty'] = 6
        ..['readinessRatio'] = 1
        ..['hasProductionMaterialChildren'] = true;
      analysis
        ..['products'] = [product, materialBackedProduct]
        ..['flatMaterials'] = <Map<String, dynamic>>[];

      await _pumpPage(
        tester,
        size: const Size(375, 812),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        analysisJson: analysis,
        theme: ThemeData.dark(),
        textScale: 1.3,
      );

      final productCard = find.byKey(
        const ValueKey('material-analysis-product-product-line-1'),
      );
      final materialBackedCard = find.byKey(
        const ValueKey('material-analysis-product-product-line-2'),
      );
      expect(
        find.descendant(of: productCard, matching: find.text('可直接自制 10 个')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('material-analysis-direct-make-product-line-1'),
        ),
        findsOneWidget,
      );
      expect(find.text('无需领料'), findsOneWidget);
      expect(
        find.descendant(of: productCard, matching: find.textContaining('齐套')),
        findsNothing,
      );
      expect(
        find.descendant(of: materialBackedCard, matching: find.text('齐套 100%')),
        findsOneWidget,
      );
      final directProgress = find.descendant(
        of: productCard,
        matching: find.byKey(
          const ValueKey('material-analysis-product-progress-product-line-1'),
        ),
      );
      final materialProgress = find.descendant(
        of: materialBackedCard,
        matching: find.byKey(
          const ValueKey('material-analysis-product-progress-product-line-2'),
        ),
      );
      expect(directProgress, findsOneWidget);
      expect(materialProgress, findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(directProgress).value, 1);
      expect(tester.widget<LinearProgressIndicator>(materialProgress).value, 1);
      expect(
        tester
            .getSize(
              find.byKey(
                const ValueKey(
                  'material-analysis-product-status-product-line-1',
                ),
              ),
            )
            .height,
        tester
            .getSize(
              find.byKey(
                const ValueKey(
                  'material-analysis-product-status-product-line-2',
                ),
              ),
            )
            .height,
      );
      expect(tester.getSemantics(directProgress).label, contains('无需领料，可直接自制'));
      expect(tester.getSemantics(directProgress).label, isNot(contains('齐套')));
      expect(
        tester.getSemantics(materialProgress).label,
        contains('齐套进度 100%'),
      );
      expect(find.textContaining('生产 BOM 策略'), findsNothing);
      expect(find.textContaining('资料异常'), findsNothing);
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'material card distinguishes exact node receipt peg from whole-kit readiness',
    (tester) async {
      final analysis = _analysisJson(const ['VIEW']);
      final firstProduct =
          (analysis['products']! as List<dynamic>).first
              as Map<String, dynamic>;
      firstProduct['readyNowQty'] = 0;
      firstProduct['readinessRatio'] = 0;
      final firstMaterial =
          (analysis['flatMaterials']! as List<dynamic>).first
              as Map<String, dynamic>;
      firstMaterial['exactPeggedQty'] = 2;
      firstMaterial['warehouseBreakdown'] = [
        {
          'warehouseId': 'warehouse-1',
          'warehouseCode': 'WH-01',
          'warehouseName': '主仓',
          'onHandQty': 5,
          'reservedQty': 0,
          'availableQty': 5,
          'ownPeggedQty': 2,
        },
      ];
      final siblingMaterial =
          (analysis['flatMaterials']! as List<dynamic>)[1]
              as Map<String, dynamic>;
      // 分仓 ownPeggedQty 是同分析同 SKU 聚合，会出现在两个兄弟节点；节点卡
      // 必须只认 exactPeggedQty，不能把聚合量重复展示两次。
      siblingMaterial['exactPeggedQty'] = 0;
      siblingMaterial['warehouseBreakdown'] = [
        {
          'warehouseId': 'warehouse-1',
          'warehouseCode': 'WH-01',
          'warehouseName': '主仓',
          'onHandQty': 5,
          'reservedQty': 0,
          'availableQty': 5,
          'ownPeggedQty': 2,
        },
      ];

      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        analysisJson: analysis,
      );

      expect(find.text('暂不可生产'), findsOneWidget);
      expect(find.text('“最多可生产”是整套齐套量；单项合格到货会在下方物料卡显示。'), findsNothing);
      final materialRow = find.byKey(
        const ValueKey('material-bom-node-material-path-1'),
      );
      await tester.scrollUntilVisible(
        materialRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(const ValueKey('material-exact-pegged-material-path-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-exact-pegged-material-path-2')),
        findsNothing,
      );
      expect(find.text('本节点合格入库绑定 2'), findsOneWidget);

      final detailsToggle = find.byKey(
        const ValueKey('material-node-details-toggle-material-path-1'),
      );
      await tester.ensureVisible(detailsToggle);
      await tester.pumpAndSettle();
      await tester.tap(detailsToggle);
      await tester.pumpAndSettle();
      expect(find.text('本节点合格入库绑定 2'), findsNWidgets(2));
      expect(
        find.byKey(const Key('material-analysis-off-target-warehouse-warning')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'completed demand separates exact receipt from public safety replenishment',
    (tester) async {
      final analysis = _buySelectionAnalysisJson();
      final firstProduct =
          (analysis['products']! as List<dynamic>).first
              as Map<String, dynamic>;
      firstProduct['readyNowQty'] = 0;
      firstProduct['readinessRatio'] = 0;
      final firstMaterial =
          (analysis['flatMaterials']! as List<dynamic>).first
              as Map<String, dynamic>;
      firstMaterial
        ..['requiredQty'] = 1000
        ..['allocatedAvailableQty'] = 0
        ..['availableQty'] = 0
        ..['shortageQty'] = 1000
        ..['demandSupplyGapQty'] = 0
        ..['safetyStockQty'] = 100000
        ..['exactPeggedQty'] = 1000
        ..['warehouseBreakdown'] = [
          {
            'warehouseId': 'warehouse-1',
            'warehouseCode': 'WH-01',
            'warehouseName': '主仓',
            'onHandQty': 2000,
            'reservedQty': 0,
            'availableQty': 0,
            'ownPeggedQty': 2000,
            'publicAvailableQty': 0,
            'openSafetySupplyQty': 0,
            'safetyReplenishmentGapQty': 100000,
          },
        ]
        ..['notifiedTargets'] = [
          {
            'target': 'BUY',
            'status': 'DONE',
            'documentType': 'PURCHASE_REQUEST',
            'documentId': 'purchase-request-done',
            'documentNo': 'CS-DONE-001',
            'allocatedQty': 1000,
          },
        ];

      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        analysisJson: analysis,
      );

      final row = find.byKey(const ValueKey('material-bom-node-buy-node-1'));
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: row, matching: find.text('本节点合格入库绑定 1000')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('合格库存保障 1000/1000(100%)')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('安全保护 100000')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('公共补库在途 0')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('公共补库待补 100000')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('本批需求已覆盖 · 公共补库在途 0'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'off-target qualified receipt explains zero and deduplicates sibling BOM nodes',
    (tester) async {
      final analysis = _analysisJson(const ['VIEW']);
      final materials = (analysis['flatMaterials']! as List<dynamic>)
          .cast<Map<String, dynamic>>();
      for (final material in materials.take(2)) {
        // 两个兄弟节点是同一 goods/color/unit 维度，服务端会返回
        // 同一份分仓聚合；告警只能报一次，不能把到货翻倍。
        material['warehouseBreakdown'] = [
          {
            'warehouseId': 'warehouse-1',
            'warehouseCode': 'WH-01',
            'warehouseName': '主仓',
            'onHandQty': 0,
            'reservedQty': 0,
            'availableQty': 0,
            'ownPeggedQty': 0,
          },
          {
            'warehouseId': 'warehouse-2',
            'warehouseCode': 'WH-02',
            'warehouseName': '委外收货仓',
            'onHandQty': 2,
            'reservedQty': 0,
            'availableQty': 2,
            'ownPeggedQty': 2,
          },
        ];
      }

      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        analysisJson: analysis,
      );

      expect(
        find.byKey(const Key('material-analysis-off-target-warehouse-warning')),
        findsOneWidget,
      );
      expect(find.text('合格到货在非分析仓，当前不计入备料'), findsOneWidget);
      expect(find.textContaining('目标仓：主仓'), findsOneWidget);
      expect(find.text('• 共享紧固件(M-1)：委外收货仓 2 个'), findsOneWidget);
      expect(find.textContaining('普通调拨不会迁移这笔分析绑定'), findsOneWidget);
    },
  );

  testWidgets(
    'accept-all-suggested-routes bulk-confirms concrete suggestions without reason',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisRoute,
        },
        allowedActions: const ['CONFIRM_ROUTES'],
        analysisId: 'analysis-1',
        seeded: false,
      );
      // Same material on two BOM paths is now two independent decisions.
      final acceptButton = find.text('采纳建议路线(2)');
      expect(acceptButton, findsOneWidget);
      final acceptWidget = tester.widget<UtenButton>(
        find.ancestor(of: acceptButton, matching: find.byType(UtenButton)),
      );
      expect(acceptWidget.type, UtenButtonType.success);
      expect(acceptWidget.icon, isNull);
      expect(find.byIcon(Icons.done_all_rounded), findsNothing);
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
    '501 suggested routes are saved as 500 plus 1 with refreshed CAS facts',
    (tester) async {
      var routeResponse = 0;
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisRoute,
        },
        allowedActions: const ['CONFIRM_ROUTES'],
        analysisJson: _bulkRouteAnalysisJson(
          count: 501,
          allowedActions: const ['CONFIRM_ROUTES'],
        ),
        responseOverride: (request) {
          if (!request.path.endsWith('/routes')) return null;
          routeResponse++;
          return _bulkRouteAnalysisJson(
            count: 501,
            allowedActions: const ['CONFIRM_ROUTES'],
            version: 3 + routeResponse,
            fingerprintChar: routeResponse == 1 ? 'b' : 'c',
            confirmedCount: routeResponse == 1 ? 500 : 501,
          );
        },
      );

      final accept = find.text('采纳建议路线(501)');
      expect(accept, findsOneWidget);
      await tester.tap(accept);
      await tester.pumpAndSettle();

      final writes = harness.requests
          .where(
            (request) =>
                request.method == 'PUT' && request.path.endsWith('/routes'),
          )
          .toList(growable: false);
      expect(writes, hasLength(2));
      final first = writes[0].data! as Map<String, dynamic>;
      final second = writes[1].data! as Map<String, dynamic>;
      expect(first['version'], 3);
      expect(first['fingerprint'], 'a' * 64);
      expect(first['decisions'], hasLength(500));
      expect(second['version'], 4);
      expect(second['fingerprint'], 'b' * 64);
      expect(second['decisions'], hasLength(1));
      expect(
        ((second['decisions'] as List).single as Map)['actionGroupKey'],
        'bulk-action-501',
      );
    },
  );

  testWidgets(
    'route retry reuses the exact timed-out second chunk idempotency key',
    (tester) async {
      var routeAttempt = 0;
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisRoute,
        },
        allowedActions: const ['CONFIRM_ROUTES'],
        analysisJson: _bulkRouteAnalysisJson(
          count: 501,
          allowedActions: const ['CONFIRM_ROUTES'],
        ),
        errorOverride: (request) {
          if (!request.path.endsWith('/routes')) return null;
          routeAttempt++;
          if (routeAttempt != 2) return null;
          return DioException(
            requestOptions: request,
            type: DioExceptionType.receiveTimeout,
            message: '服务端已成功，但客户端等待超时',
          );
        },
        responseOverride: (request) {
          if (!request.path.endsWith('/routes')) return null;
          return _bulkRouteAnalysisJson(
            count: 501,
            allowedActions: const ['CONFIRM_ROUTES'],
            version: routeAttempt == 1 ? 4 : 5,
            fingerprintChar: routeAttempt == 1 ? 'b' : 'c',
            confirmedCount: routeAttempt == 1 ? 500 : 501,
          );
        },
      );

      await tester.tap(find.text('采纳建议路线(501)'));
      await tester.pumpAndSettle();
      expect(find.text('确认路线(1)'), findsOneWidget);

      await tester.tap(find.text('确认路线(1)'));
      await tester.pumpAndSettle();

      final writes = harness.requests
          .where(
            (request) =>
                request.method == 'PUT' && request.path.endsWith('/routes'),
          )
          .toList(growable: false);
      expect(writes, hasLength(3));
      final failedChunk = writes[1].data! as Map<String, dynamic>;
      final retriedChunk = writes[2].data! as Map<String, dynamic>;
      expect(failedChunk['version'], 4);
      expect(failedChunk['fingerprint'], 'b' * 64);
      expect(failedChunk['decisions'], hasLength(1));
      expect(retriedChunk['version'], failedChunk['version']);
      expect(retriedChunk['fingerprint'], failedChunk['fingerprint']);
      expect(retriedChunk['decisions'], failedChunk['decisions']);
      expect(retriedChunk['idempotencyKey'], failedChunk['idempotencyKey']);
    },
  );

  testWidgets(
    '501 selected BUY nodes notify as 500 plus 1 with refreshed CAS facts',
    (tester) async {
      var notifyResponse = 0;
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        allowedActions: const ['NOTIFY_SUPPLY'],
        analysisJson: _bulkRouteAnalysisJson(
          count: 501,
          allowedActions: const ['NOTIFY_SUPPLY'],
          confirmedCount: 501,
        ),
        responseOverride: (request) {
          if (!request.path.endsWith('/notify')) return null;
          notifyResponse++;
          return _bulkRouteAnalysisJson(
            count: 501,
            allowedActions: const ['NOTIFY_SUPPLY'],
            version: 3 + notifyResponse,
            fingerprintChar: notifyResponse == 1 ? 'b' : 'c',
            confirmedCount: 501,
            notifiedCount: notifyResponse == 1 ? 500 : 501,
          );
        },
      );

      final selectAll = find.byKey(
        const ValueKey('material-route-select-all-BUY'),
      );
      await tester.scrollUntilVisible(
        selectAll,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(selectAll);
      await tester.pump();
      expect(find.text('提交采购需求(501)'), findsOneWidget);
      await tester.tap(find.text('提交采购需求(501)'));
      await tester.pumpAndSettle();
      await _confirmSupplyQuantityDialog(tester);

      final writes = harness.requests
          .where(
            (request) =>
                request.method == 'POST' && request.path.endsWith('/notify'),
          )
          .toList(growable: false);
      expect(writes, hasLength(2));
      final first = writes[0].data! as Map<String, dynamic>;
      final second = writes[1].data! as Map<String, dynamic>;
      expect(first['version'], 3);
      expect(first['fingerprint'], 'a' * 64);
      expect(first['actionGroupKeys'], hasLength(500));
      expect(second['version'], 4);
      expect(second['fingerprint'], 'b' * 64);
      expect(second['actionGroupKeys'], ['bulk-action-501']);
    },
  );

  testWidgets(
    'notify retry reuses the exact timed-out second chunk idempotency key',
    (tester) async {
      var notifyAttempt = 0;
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        allowedActions: const ['NOTIFY_SUPPLY'],
        analysisJson: _bulkRouteAnalysisJson(
          count: 501,
          allowedActions: const ['NOTIFY_SUPPLY'],
          confirmedCount: 501,
        ),
        errorOverride: (request) {
          if (!request.path.endsWith('/notify')) return null;
          notifyAttempt++;
          if (notifyAttempt != 2) return null;
          return DioException(
            requestOptions: request,
            type: DioExceptionType.receiveTimeout,
            message: '服务端已成功，但客户端等待超时',
          );
        },
        responseOverride: (request) {
          if (!request.path.endsWith('/notify')) return null;
          return _bulkRouteAnalysisJson(
            count: 501,
            allowedActions: const ['NOTIFY_SUPPLY'],
            version: notifyAttempt == 1 ? 4 : 5,
            fingerprintChar: notifyAttempt == 1 ? 'b' : 'c',
            confirmedCount: 501,
            notifiedCount: notifyAttempt == 1 ? 500 : 501,
          );
        },
      );

      final selectAll = find.byKey(
        const ValueKey('material-route-select-all-BUY'),
      );
      await tester.scrollUntilVisible(
        selectAll,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(selectAll);
      await tester.pump();
      await tester.tap(find.text('提交采购需求(501)'));
      await tester.pumpAndSettle();
      await _confirmSupplyQuantityDialog(tester);
      expect(find.text('提交采购需求(1)'), findsOneWidget);

      await tester.tap(find.text('提交采购需求(1)'));
      await tester.pumpAndSettle();
      await _confirmSupplyQuantityDialog(tester);

      final writes = harness.requests
          .where(
            (request) =>
                request.method == 'POST' && request.path.endsWith('/notify'),
          )
          .toList(growable: false);
      expect(writes, hasLength(3));
      final failedChunk = writes[1].data! as Map<String, dynamic>;
      final retriedChunk = writes[2].data! as Map<String, dynamic>;
      expect(failedChunk['version'], 4);
      expect(failedChunk['fingerprint'], 'b' * 64);
      expect(failedChunk['actionGroupKeys'], hasLength(1));
      expect(retriedChunk['version'], failedChunk['version']);
      expect(retriedChunk['fingerprint'], failedChunk['fingerprint']);
      expect(retriedChunk['target'], failedChunk['target']);
      expect(retriedChunk['actionGroupKeys'], failedChunk['actionGroupKeys']);
      expect(retriedChunk['idempotencyKey'], failedChunk['idempotencyKey']);
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
        'allocationPriority': 2,
      });
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: json,
      );

      // The self-make card surfaces the parent assembly it feeds into.
      expect(find.textContaining('用于组装 顶级插座'), findsOneWidget);
      // Bottom-up grouping: the plan-ready sub-assembly belongs to the first
      // action section; the blocked top product stays in the unified waiting
      // section instead of mixing into the same grid.
      final subAssembly = find.byKey(
        const ValueKey('material-analysis-product-make-comp-1'),
      );
      final topProduct = find.byKey(
        const ValueKey('material-analysis-product-product-line-1'),
      );
      final readySection = find.byKey(
        const Key('material-analysis-ready-section'),
      );
      final waitingSection = find.byKey(
        const Key('material-analysis-waiting-section'),
      );
      expect(subAssembly, findsOneWidget);
      expect(topProduct, findsOneWidget);
      expect(
        find.descendant(of: readySection, matching: subAssembly),
        findsOneWidget,
      );
      expect(
        find.descendant(of: waitingSection, matching: topProduct),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(readySection).dy,
        lessThan(tester.getTopLeft(waitingSection).dy),
      );
      await tester.tap(
        find.byKey(
          const ValueKey('material-analysis-product-select-make-comp-1'),
        ),
      );
      await tester.pump();
      expect(find.text('安排子件生产(1)'), findsOneWidget);
    },
  );

  testWidgets(
    'confirmed MAKE stays visible as a blocked candidate before child creation',
    (tester) async {
      final theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      );
      final harness = await _pumpPage(
        tester,
        size: const Size(375, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _pendingMakeCandidateAnalysisJson(),
        theme: theme,
        textScale: 1.3,
      );

      final candidate = find.byKey(
        const ValueKey('material-analysis-pending-make-pending-make-1'),
      );
      expect(candidate, findsOneWidget);
      final waitingSection = find.byKey(
        const Key('material-analysis-waiting-section'),
      );
      expect(find.text('暂不可安排 · 1'), findsOneWidget);
      expect(
        find.descendant(of: waitingSection, matching: candidate),
        findsOneWidget,
      );
      final blockedCard = tester.widget<Card>(candidate);
      final blockedShape = blockedCard.shape! as RoundedRectangleBorder;
      expect(blockedShape.side.color, theme.colorScheme.outlineVariant);
      final blockedSection = tester.widget<Container>(waitingSection);
      final blockedSectionDecoration =
          blockedSection.decoration! as BoxDecoration;
      expect(
        blockedSectionDecoration.color,
        theme.colorScheme.errorContainer.withValues(alpha: 0.2),
      );
      final blockedStatus = tester.widget<Container>(
        find.byKey(
          const ValueKey(
            'material-analysis-pending-make-status-pending-make-1',
          ),
        ),
      );
      final blockedStatusDecoration =
          blockedStatus.decoration! as BoxDecoration;
      expect(
        blockedStatusDecoration.color,
        theme.colorScheme.errorContainer.withValues(alpha: 0.5),
      );
      expect(
        find.descendant(
          of: candidate,
          matching: find.byIcon(Icons.do_not_disturb_on_outlined),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: candidate,
          matching: find.text('下层还缺 2 种物料 · 共 3 条 BOM 路径 · 其中 3 条路线待确认'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: candidate,
          matching: find.text('待办卡，非生产计划；请继续处理下方 BOM。'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey(
            'material-analysis-pending-make-select-pending-make-1',
          ),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey('material-analysis-product-select-pending-make-1'),
        ),
        findsNothing,
      );
      expect(find.byKey(const Key('batch-qty-pending-make-1')), findsNothing);
      expect(find.text('填写生产计划单'), findsNothing);
      expect(
        harness.requests.where(
          (request) =>
              request.method == 'POST' && request.path.endsWith('/notify'),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ready pending MAKE card offers batch create checkbox and bottom action',
    (tester) async {
      final theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      );
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _pendingMakeCandidateAnalysisJson(
          lowerLevelPending: false,
        ),
        theme: theme,
      );

      final candidate = find.byKey(
        const ValueKey('material-analysis-pending-make-pending-make-1'),
      );
      final readySectionFinder = find.byKey(
        const Key('material-analysis-ready-section'),
      );
      expect(find.text('可安排 · 3'), findsOneWidget);
      expect(
        find.descendant(of: readySectionFinder, matching: candidate),
        findsOneWidget,
      );
      final readySection = tester.widget<Container>(readySectionFinder);
      final readySectionDecoration = readySection.decoration! as BoxDecoration;
      expect(
        readySectionDecoration.color,
        theme.colorScheme.primaryContainer.withValues(alpha: 0.18),
      );
      expect(
        find.descendant(of: candidate, matching: find.text('勾选后创建自制子件任务')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: candidate, matching: find.text('全部 8 个')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: candidate,
          matching: find.text('创建后由有计划权限的员工填写生产数量'),
        ),
        findsOneWidget,
      );
      // 卡内不再有单卡按钮：勾选后由底部动作区统一创建。
      expect(
        find.byKey(
          const ValueKey(
            'material-analysis-pending-make-arrange-pending-make-1',
          ),
        ),
        findsNothing,
      );
      final checkbox = find.byKey(
        const ValueKey('material-analysis-pending-make-select-pending-make-1'),
      );
      expect(checkbox, findsOneWidget);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      expect(find.text('创建自制子件任务(1)'), findsOneWidget);
    },
  );

  testWidgets(
    'ready-looking MAKE candidate stays red when execution gate is closed',
    (tester) async {
      final theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      );
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _pendingMakeCandidateAnalysisJson(
          lowerLevelPending: false,
          actionable: false,
        ),
        theme: theme,
      );

      final candidate = find.byKey(
        const ValueKey('material-analysis-pending-make-pending-make-1'),
      );
      final waitingSection = find.byKey(
        const Key('material-analysis-waiting-section'),
      );
      expect(
        find.descendant(of: candidate, matching: find.text('当前不可安排，请刷新后重试')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: waitingSection, matching: candidate),
        findsOneWidget,
      );
      final blockedCard = tester.widget<Card>(candidate);
      final blockedShape = blockedCard.shape! as RoundedRectangleBorder;
      expect(blockedShape.side.color, theme.colorScheme.outlineVariant);
      // 执行门禁关闭：固定 48px 门禁图标，不出勾选框。
      expect(
        find.byKey(
          const ValueKey(
            'material-analysis-pending-make-select-pending-make-1',
          ),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: candidate,
          matching: find.byIcon(Icons.do_not_disturb_on_outlined),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'products and MAKE candidates share readiness groups while execution stays separate',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      );
      final analysis = _pendingMakeCandidateAnalysisJson(
        includeMixedReadyCandidate: true,
      );
      final products = analysis['products']! as List<dynamic>;
      (products.first as Map<String, dynamic>)
        ..['readyNowQty'] = 0
        ..['readinessRatio'] = 0;
      products.add({
        'analysisLineId': 'product-execution-1',
        'sourceType': 'STOCK',
        'goodsCode': 'P-EXEC',
        'goodsName': '已下达产品',
        'requestedQty': 5,
        'remainingQty': 0,
        'readyNowQty': 0,
        'readinessRatio': 0,
        'allocationPriority': 3,
        'planExecutionStatus': 'READY',
        'latestPlanId': 'plan-execution-1',
        'latestPlanNo': 'PP-EXEC-001',
      });
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: analysis,
        theme: theme,
        textScale: 1.3,
      );

      expect(find.text('可安排 2 · 受阻 2 · 已转生产 1 · 已选 0'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^可安排，共 2 项')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^暂不可安排，共 2 项')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('已转生产，共 1 项')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('下层备料中，不可排产')), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('选择已齐套自制件 创建自制子件任务')),
        findsOneWidget,
      );
      final readySection = find.byKey(
        const Key('material-analysis-ready-section'),
      );
      final waitingSection = find.byKey(
        const Key('material-analysis-waiting-section'),
      );
      final transferredSection = find.byKey(
        const Key('material-analysis-transferred-section'),
      );
      final viewportHeight = tester.getSize(find.byType(Scaffold).first).height;
      expect(tester.getTopLeft(waitingSection).dy, lessThan(viewportHeight));
      final readyCandidate = find.byKey(
        const ValueKey('material-analysis-pending-make-pending-make-ready-1'),
      );
      final blockedCandidate = find.byKey(
        const ValueKey('material-analysis-pending-make-pending-make-1'),
      );
      final readyProduct = find.byKey(
        const ValueKey('material-analysis-product-product-line-2'),
      );
      final blockedProduct = find.byKey(
        const ValueKey('material-analysis-product-product-line-1'),
      );
      final executionProduct = find.byKey(
        const ValueKey('material-analysis-product-product-execution-1'),
      );
      expect(
        find.descendant(of: readySection, matching: readyCandidate),
        findsOneWidget,
      );
      expect(
        find.descendant(of: readySection, matching: readyProduct),
        findsOneWidget,
      );
      expect(
        find.descendant(of: waitingSection, matching: blockedCandidate),
        findsOneWidget,
      );
      expect(
        find.descendant(of: waitingSection, matching: blockedProduct),
        findsOneWidget,
      );
      expect(
        find.descendant(of: transferredSection, matching: executionProduct),
        findsOneWidget,
      );
      expect(
        find.descendant(of: waitingSection, matching: executionProduct),
        findsNothing,
      );
      expect(
        tester.getTopLeft(readySection).dy,
        lessThan(tester.getTopLeft(waitingSection).dy),
      );
      expect(
        tester.getTopLeft(waitingSection).dy,
        lessThan(tester.getTopLeft(transferredSection).dy),
      );
      final blockedCandidateCard = tester.widget<Card>(blockedCandidate);
      final blockedProductCard = tester.widget<Card>(blockedProduct);
      final blockedCandidateShape =
          blockedCandidateCard.shape! as RoundedRectangleBorder;
      final blockedProductShape =
          blockedProductCard.shape! as RoundedRectangleBorder;
      expect(blockedCandidateCard.color, blockedProductCard.color);
      expect(blockedCandidateCard.elevation, blockedProductCard.elevation);
      expect(
        blockedCandidateShape.borderRadius,
        blockedProductShape.borderRadius,
      );
      expect(blockedCandidateShape.side, blockedProductShape.side);
      expect(
        blockedCandidateShape.side.color,
        theme.colorScheme.outlineVariant,
      );
      final blockedCandidateState = find.byKey(
        const ValueKey(
          'material-analysis-task-state-pending-make-pending-make-1',
        ),
      );
      final blockedProductState = find.byKey(
        const ValueKey('material-analysis-task-state-product-product-line-1'),
      );
      for (final state in [blockedCandidateState, blockedProductState]) {
        expect(tester.getSize(state), const Size(48, 48));
        expect(
          find.descendant(
            of: state,
            matching: find.byIcon(Icons.do_not_disturb_on_outlined),
          ),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(of: blockedCandidate, matching: find.byType(Checkbox)),
        findsNothing,
      );
      expect(
        find.descendant(of: readyCandidate, matching: find.byType(Checkbox)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: blockedProduct, matching: find.byType(Checkbox)),
        findsNothing,
      );

      final blockedCandidateStatusFinder = find.byKey(
        const ValueKey('material-analysis-pending-make-status-pending-make-1'),
      );
      final blockedProductStatusFinder = find.byKey(
        const ValueKey('material-analysis-product-status-product-line-1'),
      );
      final blockedCandidateStatus = tester.widget<Container>(
        blockedCandidateStatusFinder,
      );
      final blockedProductStatus = tester.widget<Container>(
        blockedProductStatusFinder,
      );
      final blockedCandidateDecoration =
          blockedCandidateStatus.decoration! as BoxDecoration;
      final blockedProductDecoration =
          blockedProductStatus.decoration! as BoxDecoration;
      expect(blockedCandidateStatus.padding, blockedProductStatus.padding);
      expect(
        blockedCandidateDecoration.borderRadius,
        blockedProductDecoration.borderRadius,
      );
      expect(blockedCandidateDecoration.color, blockedProductDecoration.color);
      expect(
        blockedCandidateDecoration.border,
        blockedProductDecoration.border,
      );
      expect(
        find.descendant(
          of: blockedProduct,
          matching: find.byKey(
            const ValueKey('material-analysis-product-progress-product-line-1'),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: blockedCandidateStatusFinder,
          matching: find.byType(LinearProgressIndicator),
        ),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const Key('material-analysis-product-select-all')),
      );
      await tester.pump();
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(
                const ValueKey(
                  'material-analysis-product-select-product-line-2',
                ),
              ),
            )
            .value,
        isTrue,
      );
      expect(
        find.byKey(
          const ValueKey('material-analysis-product-select-product-line-1'),
        ),
        findsNothing,
      );
      expect(find.byKey(const Key('batch-qty-product-line-1')), findsNothing);
      expect(
        find.byKey(
          const ValueKey(
            'material-analysis-product-select-product-execution-1',
          ),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey(
            'material-analysis-product-select-pending-make-ready-1',
          ),
        ),
        findsNothing,
      );
      expect(find.text('可安排 2 · 受阻 2 · 已转生产 1 · 已选 1'), findsOneWidget);

      tester.view.physicalSize = const Size(375, 900);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: readySection, matching: readyCandidate),
        findsOneWidget,
      );
      expect(
        find.descendant(of: readySection, matching: readyProduct),
        findsOneWidget,
      );
      expect(
        find.descendant(of: waitingSection, matching: blockedCandidate),
        findsOneWidget,
      );
      expect(
        find.descendant(of: waitingSection, matching: blockedProduct),
        findsOneWidget,
      );
      expect(
        find.descendant(of: transferredSection, matching: executionProduct),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(readyCandidate).dy,
        lessThan(tester.getTopLeft(readyProduct).dy),
      );
      expect(
        tester.getTopLeft(blockedCandidate).dy,
        lessThan(tester.getTopLeft(blockedProduct).dy),
      );
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(
                const ValueKey(
                  'material-analysis-product-select-product-line-2',
                ),
              ),
            )
            .value,
        isTrue,
      );
      final compactBatchField = find.byKey(
        const Key('batch-qty-product-line-2'),
      );
      final compactBatchLabel = find.byKey(
        const ValueKey('batch-qty-label-product-line-2'),
      );
      final compactBatchHelper = find.byKey(
        const ValueKey('batch-qty-helper-product-line-2'),
      );
      final compactBatchSemantics = find.byKey(
        const ValueKey('batch-qty-semantics-product-line-2'),
      );
      await tester.ensureVisible(compactBatchField);
      await tester.pumpAndSettle();
      expect(compactBatchField.hitTestable(), findsOneWidget);
      expect(
        find.descendant(of: readyProduct, matching: compactBatchLabel),
        findsOneWidget,
      );
      expect(
        find.descendant(of: readyProduct, matching: compactBatchHelper),
        findsOneWidget,
      );
      expect(tester.widget<Text>(compactBatchLabel).style?.color, Colors.white);
      expect(
        tester.widget<Text>(compactBatchHelper).style?.color,
        Colors.white70,
      );
      expect(
        tester.getBottomRight(compactBatchLabel).dy,
        lessThan(tester.getTopLeft(compactBatchField).dy),
      );
      expect(
        tester.widget<Semantics>(compactBatchSemantics).properties.label,
        '本批生产数量',
      );
      expect(tester.widget<TextField>(compactBatchField).controller?.text, '2');
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('real MAKE child replaces candidate without hiding parent', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
      },
      analysisJson: _pendingMakeCandidateAnalysisJson(includeRealChild: true),
    );

    expect(
      find.byKey(
        const ValueKey('material-analysis-pending-make-pending-make-1'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(
        const ValueKey('material-analysis-product-pending-make-child-1'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('material-analysis-product-product-line-1')),
      findsOneWidget,
    );
  });

  testWidgets(
    'pending MAKE candidates render 20 first and continue on demand',
    (tester) async {
      final json = _analysisJson(const ['VIEW'])
        ..['flatMaterials'] = [
          for (var index = 1; index <= 21; index++)
            {
              ..._routeMaterial(
                id: 'pending-bulk-$index',
                nodeKey: 'pending-bulk-node-$index',
                actionGroupKey: 'pending-bulk-action-$index',
                goodsCode: 'MAKE-BULK-$index',
                goodsName: '待自制件 $index',
                route: 'MAKE',
                controlStage: 'ASSEMBLY',
              ),
              'lowerLevelPending': true,
            },
        ];
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        allowedActions: const ['VIEW'],
        analysisJson: json,
      );

      final pendingCards = find.byWidgetPredicate((widget) {
        final key = widget.key;
        return widget is Card &&
            key is ValueKey<String> &&
            key.value.startsWith(
              'material-analysis-pending-make-pending-bulk-',
            );
      });
      expect(pendingCards, findsNWidgets(20));
      final showMore = find.byKey(
        const Key('material-analysis-show-more-pending-make'),
      );
      expect(find.text('继续显示待自制件(还有 1 个)'), findsOneWidget);
      tester.widget<UtenButton>(showMore).onPressed!();
      await tester.pump();
      expect(pendingCards, findsNWidgets(21));
      expect(showMore, findsNothing);
    },
  );

  testWidgets(
    'BOM paths stay independent and suggested route can be adopted inline',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
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
      // 节点行新增备料进度条后行高增加，第二行可能落在 SliverList 懒构建
      // 窗口之外；滚动到它出现再断言。不改变“两条路径各自独立”的验证目标。
      await tester.scrollUntilVisible(
        secondRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
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
      expect(tester.getSize(details).height, greaterThanOrEqualTo(40));
      expect(tester.getSemantics(details).label, contains('展开共享紧固件详情'));
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(tester.getSemantics(details).label, contains('收起共享紧固件详情'));
      semantics.dispose();
      // 路线操作已移到右操作区：详情内不再有路线下拉；未确认路线时
      // 右操作区提供「更换路线」入口（点按弹路线面板，选中即保存）。
      expect(
        find.byKey(const ValueKey('material-route-change-material-path-1')),
        findsOneWidget,
      );
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
    'unconfirmed route gates require explicit adoption and never write implicitly',
    (tester) async {
      const actions = ['CONFIRM_ROUTES', 'NOTIFY_SUPPLY'];

      Map<String, dynamic> routeState({
        required bool buyConfirmed,
        required bool subcontractConfirmed,
      }) {
        final json = _analysisJson(actions);
        final materials = (json['flatMaterials'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        final buy = materials.firstWhere(
          (material) => material['materialLineId'] == 'material-path-1',
        );
        final subcontract = materials.firstWhere(
          (material) => material['materialLineId'] == 'material-path-2',
        );
        subcontract['sourceSuggestion'] = 'SUBCONTRACT';
        if (buyConfirmed) {
          buy
            ..['sourceConfirmed'] = 'BUY'
            ..['routeConfirmed'] = true;
        }
        if (subcontractConfirmed) {
          subcontract
            ..['sourceConfirmed'] = 'SUBCONTRACT'
            ..['routeConfirmed'] = true;
        }
        return json;
      }

      var routeWrites = 0;
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisNotify,
        },
        allowedActions: actions,
        analysisJson: routeState(
          buyConfirmed: false,
          subcontractConfirmed: false,
        ),
        responseOverride: (request) {
          if (!request.path.endsWith('/routes')) return null;
          routeWrites++;
          return routeState(
            buyConfirmed: true,
            subcontractConfirmed: routeWrites > 1,
          );
        },
      );

      final buyGate = find.byKey(
        const ValueKey('material-bom-gate-material-path-1'),
      );
      await tester.scrollUntilVisible(
        buyGate,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.getSize(buyGate).height, greaterThanOrEqualTo(48));
      expect(
        find.descendant(
          of: buyGate,
          matching: find.byIcon(Icons.route_outlined),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: buyGate, matching: find.byType(Checkbox)),
        findsNothing,
      );
      // 门禁图标可点按查看引导，且不会触发任何写入。
      await tester.tap(buyGate);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        harness.requests.where((request) => request.method == 'PUT'),
        isEmpty,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('material-bom-node-material-path-1')),
          matching: find.byType(Checkbox),
        ),
        findsNothing,
      );
      expect(
        harness.requests.where((request) => request.method == 'PUT'),
        isEmpty,
      );

      await tester.tap(
        find.byKey(const ValueKey('material-adopt-route-material-path-1')),
      );
      await tester.pumpAndSettle();
      expect(
        harness.requests.where((request) => request.method == 'PUT'),
        hasLength(1),
      );
      expect(buyGate, findsNothing);
      final buyCheckbox = find.byKey(
        const ValueKey('material-bom-select-material-path-1'),
      );
      expect(
        find.descendant(of: buyCheckbox, matching: find.byType(Checkbox)),
        findsOneWidget,
      );
      await tester.tap(buyCheckbox);
      await tester.pump();
      expect(find.text('提交采购需求(1)'), findsOneWidget);

      final subcontractGate = find.byKey(
        const ValueKey('material-bom-gate-material-path-2'),
      );
      await tester.ensureVisible(subcontractGate);
      expect(tester.getSize(subcontractGate).height, greaterThanOrEqualTo(48));
      expect(
        find.descendant(
          of: subcontractGate,
          matching: find.byIcon(Icons.route_outlined),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: subcontractGate, matching: find.byType(Checkbox)),
        findsNothing,
      );
      expect(
        harness.requests.where((request) => request.method == 'PUT'),
        hasLength(1),
      );

      await tester.tap(
        find.byKey(const ValueKey('material-adopt-route-material-path-2')),
      );
      await tester.pumpAndSettle();
      // Refreshing the second route must preserve the already selected BUY
      // node instead of silently dropping a planner's earlier selection.
      expect(find.text('提交采购需求(1)'), findsOneWidget);
      expect(
        harness.requests.where((request) => request.method == 'PUT'),
        hasLength(2),
      );
      expect(subcontractGate, findsNothing);
      final subcontractCheckbox = find.byKey(
        const ValueKey('material-bom-select-material-path-2'),
      );
      expect(
        find.descendant(
          of: subcontractCheckbox,
          matching: find.byType(Checkbox),
        ),
        findsOneWidget,
      );
      await tester.tap(subcontractCheckbox);
      await tester.pump();
      // V458：按钮统一为「下达委外」；有子层由服务端转前置自制。
      expect(find.text('下达委外(1)'), findsOneWidget);
    },
  );

  testWidgets(
    'notified SUBCONTRACT node exposes the exact pre-production task entry',
    (tester) async {
      final analysis = _buySelectionAnalysisJson();
      final subcontract = (analysis['flatMaterials'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .singleWhere(
            (material) => material['materialLineId'] == 'subcontract-line-1',
          );
      subcontract
        ..['lowerLevelPending'] = false
        ..['demandSupplyGapQty'] = 8
        ..['notifiedTargets'] = [
          {
            'target': 'SUBCONTRACT',
            'documentType': 'SUBCONTRACT_APPLICATION',
            'documentId': 'subcontract-application-1',
            'documentNo': 'WW-SQ-001',
            'status': 'CREATED',
            'allocatedQty': 8,
          },
        ];

      await _pumpPage(
        tester,
        size: const Size(375, 900),
        permissions: const {
          Perm.productionMaterialAnalysisView,
          Perm.subcontractPreparationView,
          Perm.subcontractPreparationStart,
        },
        analysisId: 'analysis-1',
        seeded: false,
        analysisJson: analysis,
        withSubcontractPreparationRoute: true,
        theme: ThemeData.dark(),
        textScale: 1.3,
      );

      final row = find.byKey(
        const ValueKey('material-bom-node-subcontract-node-1'),
      );
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      final action = find.descendant(
        of: row,
        matching: find.byKey(
          const ValueKey(
            'material-open-subcontract-preparation-subcontract-line-1',
          ),
        ),
      );
      expect(action, findsOneWidget);
      expect(
        find.descendant(of: action, matching: find.text('安排前置自制')),
        findsOneWidget,
      );

      await tester.scrollUntilVisible(
        action,
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text('prep-analysis-1-subcontract-line-1'), findsOneWidget);
      expect(tester.takeException(), isNull);
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
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisRoute,
        },
        allowedActions: const ['CONFIRM_ROUTES'],
        analysisJson: json,
      );

      await _chooseRoute(tester, '自制');
      expect(find.byKey(const Key('material-route-reason')), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      // 取消原因填写：不落库、不发请求，路线仍未确认（不会出现深绿已确认按钮）。
      expect(
        harness.requests.where((request) => request.method == 'PUT'),
        isEmpty,
      );
      expect(find.text('路线 · 自制'), findsNothing);

      await _chooseRoute(tester, '自制');
      await tester.enterText(
        find.byKey(const Key('material-route-reason')),
        '交期紧急，改为车间自制',
      );
      await tester.tap(find.text('确认路线'));
      await tester.pumpAndSettle();

      // 偏离建议的路线填完原因后立即保存（单条 PUT；幂等键与「采用建议」同口径）。
      final routeRequest = harness.requests.singleWhere(
        (request) => request.method == 'PUT',
      );
      expect(
        routeRequest.path,
        '/production/material-analyses/analysis-1/routes',
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
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
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
      // VIEW 档：右操作区不提供任何路线写入口（更换/选择路线按钮均不出现）。
      expect(
        find.byKey(const ValueKey('material-route-change-material-path-1')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('material-route-pick-material-path-1')),
        findsNothing,
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
    'FQC recovery-only analysis hides ordinary supply and plan actions',
    (tester) async {
      final json = _analysisJson(const ['VIEW', 'FQC_REPLENISHMENT_CONFIRM'])
        ..['fqcReplenishmentOnly'] = true
        ..['fqcRecoveryAuthorizationId'] = 'authorization-1';
      await _pumpPage(
        tester,
        size: const Size(375, 900),
        permissions: const {
          Perm.productionMaterialAnalysisView,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisNotify,
          Perm.productionMaterialAnalysisGenerate,
          Perm.productionPlanApprove,
        },
        analysisId: 'analysis-1',
        analysisJson: json,
      );

      expect(
        find.textContaining('仅用于冻结 FQC 补产 BOM', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('返回“FQC 补产待办”', skipOffstage: false),
        findsOneWidget,
      );
      expect(find.byKey(const Key('material-analysis-generate')), findsNothing);
      expect(
        find.byKey(const Key('material-analysis-notify-BUY')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inactive deep node still shows its own demand allocation and warehouse stock',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(520, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
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
        find.descendant(of: dependencyRow, matching: find.text('本批需求 20')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dependencyRow,
          matching: find.text('合格库存保障 4/20(20%)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dependencyRow, matching: find.text('公共可用 7')),
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
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
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
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
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
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
      },
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
    expect(find.textContaining('本批需求 '), findsWidgets);
    expect(find.textContaining('合格库存保障 '), findsWidgets);
    // 本批覆盖只认 max(已分配, exact)，安全保护单独展示。
    expect(find.textContaining('3/16(19%)'), findsWidgets);
    expect(find.text('计划日期 未设置'), findsNothing);
    expect(find.byKey(const Key('material-analysis-generate')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'default BOM view shows all nodes and precedes the shortage filter',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final json = _makeTreeAnalysisJson()..['allowedActions'] = const ['VIEW'];
      final materials = (json['flatMaterials'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final coveredChild = materials.firstWhere(
        (material) => material['materialLineId'] == 'buy-child',
      );
      coveredChild
        ..['allocatedAvailableQty'] = 10
        ..['availableQty'] = 10
        ..['shortageQty'] = 0;

      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        allowedActions: const ['VIEW'],
        analysisJson: json,
      );

      final viewAll = find.byKey(const ValueKey('material-bom-view-all'));
      final viewShortage = find.byKey(
        const ValueKey('material-bom-view-shortage'),
      );
      await tester.scrollUntilVisible(
        viewAll,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('只看缺料 2'), findsOneWidget);
      expect(find.text('待确认路线 0'), findsOneWidget);
      expect(find.text('全部 BOM 3'), findsOneWidget);
      expect(
        tester.getTopLeft(viewAll).dx,
        lessThan(tester.getTopLeft(viewShortage).dx),
      );
      expect(find.text('筛选命中 3 条；保留上级后共 3 条 / 全部 3 条'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('material-bom-node-node-buy-child')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(const ValueKey('material-bom-node-node-buy-child')),
        findsOneWidget,
      );
      final completedFill = find.byKey(
        const ValueKey('material-node-rail-fill-buy-child'),
      );
      final completedDecoration =
          tester.widget<DecoratedBox>(completedFill).decoration
              as BoxDecoration;
      expect(completedDecoration.gradient, isNull);
      expect(
        completedDecoration.color,
        Theme.of(tester.element(completedFill)).colorScheme.primary,
      );
      expect(tester.getSize(completedFill).width, greaterThanOrEqualTo(8));
      expect(tester.getSize(completedFill).height, greaterThan(0));
      expect(find.text('备货完成'), findsOneWidget);
      expect(find.bySemanticsLabel('备货完成'), findsOneWidget);

      await tester.tap(viewShortage);
      await tester.pumpAndSettle();
      expect(find.text('筛选命中 2 条；保留上级后共 2 条 / 全部 3 条'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('material-bom-node-node-buy-child')),
        findsNothing,
      );
      semantics.dispose();
    },
  );

  testWidgets(
    'BOM child search keeps its product header and nonmatching ancestor context',
    (tester) async {
      final json = _makeTreeAnalysisJson()..['allowedActions'] = const ['VIEW'];
      final materials = (json['flatMaterials'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final parent = materials.firstWhere(
        (material) => material['materialLineId'] == 'make-path-1',
      );
      parent
        ..['allocatedAvailableQty'] = 10
        ..['availableQty'] = 10
        ..['shortageQty'] = 0;

      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        allowedActions: const ['VIEW'],
        analysisJson: json,
      );

      final search = find.byKey(const Key('material-bom-search'));
      await tester.scrollUntilVisible(
        search,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(search, '外箱依赖');
      // UtenSearchBar 内置 300ms 防抖：先推进时间让过滤生效，再等帧稳定。
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.text('筛选命中 1 条；保留上级后共 2 条 / 全部 3 条'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('material-bom-product-product-line-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-bom-node-node-make-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-bom-node-node-buy-child')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-bom-node-node-make-2')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'large product set renders 60 cards first and continues on demand',
    (tester) async {
      final json = _analysisJson(const ['VIEW']);
      json
        ..['products'] = [
          for (var index = 1; index <= 61; index++)
            {
              'analysisLineId': 'bulk-product-$index',
              'sourceType': 'STOCK',
              'sourceRef': 'STOCK-$index',
              'goodsCode': 'BULK-$index',
              'goodsName': '批量产品 $index',
              'requestedQty': 1,
              'remainingQty': 1,
              'readyNowQty': 1,
              'readyByDateQty': 1,
              'readinessRatio': 1,
              'allocationPriority': index,
            },
        ]
        ..['flatMaterials'] = <Map<String, dynamic>>[];

      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        allowedActions: const ['VIEW'],
        analysisJson: json,
      );

      expect(
        find.byKey(const ValueKey('material-analysis-product-bulk-product-60')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-analysis-product-bulk-product-61')),
        findsNothing,
      );
      final showMore = find.byKey(
        const Key('material-analysis-show-more-products'),
      );
      expect(find.text('继续显示下一批(还有 1 个)'), findsOneWidget);
      final button = tester.widget<UtenButton>(showMore);
      expect(button.onPressed, isNotNull);
      button.onPressed!();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('material-analysis-product-bulk-product-61')),
        findsOneWidget,
      );
      expect(showMore, findsNothing);
    },
  );

  testWidgets(
    'product and BOM branch are expanded by default and independently foldable',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        allowedActions: const ['VIEW'],
        analysisJson: _makeTreeAnalysisJson()
          ..['allowedActions'] = const ['VIEW'],
      );

      final productToggle = find.byKey(
        const ValueKey('material-bom-product-toggle-product-line-1'),
      );
      final makeNode = find.byKey(
        const ValueKey('material-bom-node-node-make-1'),
      );
      final buyChild = find.byKey(
        const ValueKey('material-bom-node-node-buy-child'),
      );
      await tester.scrollUntilVisible(
        productToggle,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.scrollUntilVisible(
        makeNode,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.scrollUntilVisible(
        buyChild,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(makeNode, findsOneWidget);
      expect(buyChild, findsOneWidget);

      await tester.ensureVisible(productToggle);
      await tester.tap(productToggle);
      await tester.pumpAndSettle();
      expect(makeNode, findsNothing);
      expect(buyChild, findsNothing);

      await tester.ensureVisible(productToggle);
      await tester.tap(productToggle);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        makeNode,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.scrollUntilVisible(
        buyChild,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(makeNode, findsOneWidget);
      expect(buyChild, findsOneWidget);

      final branchToggle = find.byKey(
        const ValueKey('material-bom-branch-toggle-node-make-1'),
      );
      await tester.tap(branchToggle);
      await tester.pumpAndSettle();
      expect(makeNode, findsOneWidget);
      expect(buyChild, findsNothing);

      await tester.tap(branchToggle);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        buyChild,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(buyChild, findsOneWidget);
    },
  );

  testWidgets(
    'route rows support tri-state selection, deep-green state and subset notify',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _buySelectionAnalysisJson(),
        responseOverride: (request) => request.path.endsWith('/notify')
            ? _buySelectionNotifiedAnalysisJson()
            : null,
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
      expect(find.text('提交采购需求(2)'), findsOneWidget);

      final first = find.byKey(
        const ValueKey('material-bom-select-buy-line-1'),
      );
      await tester.tap(first);
      await tester.pump();
      expect(tester.widget<Checkbox>(header).value, isNull);
      expect(find.text('提交采购需求(1)'), findsOneWidget);

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
      await tester.scrollUntilVisible(
        subcontract,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      await tester.tap(subcontract);
      await tester.pump();
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(of: subcontract, matching: find.byType(Checkbox)),
            )
            .value,
        isTrue,
      );

      final buyNotify = find.text('提交采购需求(1)');
      await tester.ensureVisible(buyNotify);
      await tester.pump();
      await tester.tap(buyNotify);
      await tester.pumpAndSettle();
      await _confirmSupplyQuantityDialog(tester);
      final request = harness.requests.singleWhere(
        (request) => request.path.endsWith('/notify'),
      );
      expect(request.data, {
        'version': 3,
        'fingerprint': 'a' * 64,
        'idempotencyKey': isA<String>(),
        'target': 'BUY',
        'actionGroupKeys': ['buy-action-2'],
        // 数量对话框默认按「缺口 − 在途」全量提交：缺口 8、在途 0 → 8。
        'quantities': [
          {
            'actionGroupKey': 'buy-action-2',
            'qty': 8.0,
            'safetyReplenishmentQty': 0.0,
          },
        ],
      });
      expect(tester.widget<Checkbox>(header).value, isFalse);
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(of: subcontract, matching: find.byType(Checkbox)),
            )
            .value,
        isTrue,
      );
    },
  );

  testWidgets(
    'BUY quantity dialog deduplicates safety gap and submits visible two-slice totals',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(375, 800),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        allowedActions: const ['NOTIFY_SUPPLY'],
        analysisJson: _buySafetySplitAnalysisJson(),
      );

      final selectAll = find.byKey(
        const ValueKey('material-route-select-all-BUY'),
      );
      await tester.scrollUntilVisible(
        selectAll,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(tester.element(selectAll), alignment: 0.5);
      await tester.pump();
      await tester.tap(selectAll);
      await tester.pump();
      await tester.tap(find.text('提交采购需求(2)'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('supply-quantity-dialog')), findsOneWidget);
      expect(find.text('公共安全库存补库 6 个'), findsOneWidget);
      expect(find.textContaining('安全缺口已在本批另一行计入'), findsOneWidget);
      expect(
        find.textContaining('本批生产需求 16 + 公共安全库存补库 6 = 预计总量 22'),
        findsOneWidget,
      );
      expect(
        tester.getSize(
          find.byKey(const ValueKey('supply-qty-step--1-buy-action-1')),
        ),
        const Size(48, 48),
      );
      expect(tester.takeException(), isNull);

      await _confirmSupplyQuantityDialog(tester);
      final request = harness.requests.singleWhere(
        (request) => request.path.endsWith('/notify'),
      );
      final data = request.data! as Map<String, dynamic>;
      expect(data['quantities'], [
        {
          'actionGroupKey': 'buy-action-1',
          'qty': 8.0,
          'safetyReplenishmentQty': 6.0,
        },
        {
          'actionGroupKey': 'buy-action-2',
          'qty': 8.0,
          'safetyReplenishmentQty': 0.0,
        },
      ]);
    },
  );

  testWidgets(
    'SUBCONTRACT safety gap is fail-closed with a clear BUY-only reason',
    (tester) async {
      final analysis = _buySelectionAnalysisJson();
      final materials = (analysis['flatMaterials'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final subcontract = materials.singleWhere(
        (material) => material['sourceConfirmed'] == 'SUBCONTRACT',
      );
      subcontract
        ..['demandSupplyGapQty'] = 8
        ..['safetyStockQty'] = 10
        ..['warehouseBreakdown'] = [
          {
            'warehouseId': 'warehouse-1',
            'publicAvailableQty': 2,
            'openSafetySupplyQty': 2,
            'safetyReplenishmentGapQty': 6,
          },
        ];
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        allowedActions: const ['NOTIFY_SUPPLY'],
        analysisJson: analysis,
      );

      final row = find.byKey(
        const ValueKey('material-bom-node-subcontract-node-1'),
      );
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: row, matching: find.text('仅采购可补安全库存')),
        findsWidgets,
      );
      await tester.tap(
        find.descendant(
          of: row,
          matching: find.byKey(
            const ValueKey('material-bom-gate-subcontract-line-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('本版本仅采购路线支持公共安全补库'), findsWidgets);
      expect(
        harness.requests.where((request) => request.path.endsWith('/notify')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'MAKE tree preserves DFS order without merging repeated material paths',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
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
      // 行加高后，未进入视口的行在懒加载列表里不会构建，先滚动到可见再断言。
      final make1 = find.byKey(const ValueKey('material-bom-node-node-make-1'));
      final make2 = find.byKey(const ValueKey('material-bom-node-node-make-2'));
      final buyChild = find.byKey(
        const ValueKey('material-bom-node-node-buy-child'),
      );
      await tester.scrollUntilVisible(
        make1,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(make1, findsOneWidget);
      // DFS：父件 node-make-1 行在子件 node-buy-child 行之上（两行相邻同屏）。
      expect(buyChild, findsOneWidget);
      expect(
        tester.getTopLeft(make1).dy,
        lessThan(tester.getTopLeft(buyChild).dy),
      );
      await tester.scrollUntilVisible(
        make2,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(make2, findsOneWidget);
      // depth>1 缺料件（外箱依赖，层级 2）也可直接操作：带勾选框。
      expect(
        find.descendant(of: buyChild, matching: find.byType(Checkbox)),
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
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
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
      final selectControl = find.byKey(
        const ValueKey('material-bom-select-buy-child'),
      );
      await tester.ensureVisible(selectControl);
      await tester.pumpAndSettle();
      expect(tester.getSize(selectControl).height, greaterThanOrEqualTo(48));
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(
                of: selectControl,
                matching: find.byType(Checkbox),
              ),
            )
            .onChanged,
        isNotNull,
      );
      await tester.tap(selectControl);
      await tester.pump();
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(
                of: selectControl,
                matching: find.byType(Checkbox),
              ),
            )
            .value,
        isTrue,
      );
      expect(find.text('提交采购需求(1)'), findsOneWidget);
      // 路线操作在右操作区（不在详情里）：depth>1 缺料件同样可换路线——
      // 点「更换路线/选择路线」弹出路线面板（采购/委外/自制三条）。
      var routeButton = find.descendant(
        of: depNode,
        matching: find.byKey(const ValueKey('material-route-change-buy-child')),
      );
      if (routeButton.evaluate().isEmpty) {
        routeButton = find.descendant(
          of: depNode,
          matching: find.byKey(const ValueKey('material-route-pick-buy-child')),
        );
      }
      expect(routeButton, findsOneWidget);
      await tester.tap(routeButton);
      await tester.pumpAndSettle();
      expect(find.text('选择供料路线'), findsOneWidget);
      // 不选直接关面板（点遮罩），不写任何路线决定。
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
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
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
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
      final gateControl = find.byKey(
        const ValueKey('material-bom-gate-make-path-1'),
      );
      expect(tester.getSize(gateControl).height, greaterThanOrEqualTo(48));
      expect(
        find.descendant(
          of: gateControl,
          matching: find.byIcon(Icons.account_tree_outlined),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: gateControl, matching: find.byType(Checkbox)),
        findsNothing,
      );
      // 点按门禁图标查看原因，不会创建任务。
      await tester.ensureVisible(gateControl);
      await tester.pumpAndSettle();
      await tester.tap(gateControl);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(of: makeRow, matching: find.byType(Checkbox)),
        findsNothing,
      );
      expect(
        harness.requests.where((request) => request.path.endsWith('/notify')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'pending MAKE create stays on page for quantities, then wizard on arrange',
    (tester) async {
      final initial = _makeTreeAnalysisJson()
        ..['allowedActions'] = const ['NOTIFY_SUPPLY', 'GENERATE_PLAN'];
      final notified = _makeReadyChildAnalysisJson();
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: initial,
        responseOverride: (request) =>
            request.path.endsWith('/notify') ? notified : null,
      );

      final candidate = find.byKey(
        const ValueKey('material-analysis-pending-make-make-path-1'),
      );
      expect(
        find.descendant(of: candidate, matching: find.text('全部 8 个')),
        findsOneWidget,
      );
      // 两段式第一步：勾选候选卡 → 底部「创建子件并填写生产数量」。
      final checkbox = find.byKey(
        const ValueKey('material-analysis-pending-make-select-make-path-1'),
      );
      expect(checkbox, findsOneWidget);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      final createButton = find.text('创建子件并填写生产数量(1)');
      expect(createButton, findsOneWidget);
      await tester.ensureVisible(createButton);
      await tester.tap(createButton);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('supply-quantity-dialog')), findsNothing);

      final notify = harness.requests.singleWhere(
        (request) => request.path.endsWith('/notify'),
      );
      expect(notify.data, {
        'version': 3,
        'fingerprint': 'a' * 64,
        'idempotencyKey': isA<String>(),
        'target': 'MAKE',
        'actionGroupKeys': ['make-action-1'],
        'quantities': [
          {
            'actionGroupKey': 'make-action-1',
            'qty': 8.0,
            'safetyReplenishmentQty': 0.0,
          },
        ],
      });
      // 创建后不跳计划单：留在本页，子件已勾选并预填数量。
      expect(find.text('填写生产计划单'), findsNothing);
      expect(
        find.byKey(const Key('batch-qty-make-child-ready-1')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('batch-qty-make-child-ready-1')),
            )
            .controller
            ?.text,
        '8',
      );
      expect(find.text('安排子件生产(1)'), findsOneWidget);

      // 第二步：点「安排子件生产」才进入计划向导。
      final arrange = find.text('安排子件生产(1)');
      await tester.ensureVisible(arrange);
      await tester.tap(arrange);
      await tester.pumpAndSettle();
      expect(find.text('填写生产计划单'), findsWidgets);
      final wizardQty = find.byKey(
        const ValueKey('production-plan-wizard-qty-make-child-ready-1'),
      );
      expect(wizardQty, findsOneWidget);
      expect(tester.widget<TextFormField>(wizardQty).controller?.text, '8');
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
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
        Perm.productionMaterialAnalysisNotify,
        Perm.productionPlanView,
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
      find.descendant(of: makeRow, matching: find.text('生产执行中 · 执行进度待回传')),
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
    'completed MAKE leaves top cards but keeps workflow and plan deep link in BOM detail',
    (tester) async {
      final analysis = _completedMakeAnalysisJson();
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
          Perm.productionPlanView,
        },
        analysisJson: analysis,
        withPlanRoute: true,
        responseOverride: (request) {
          if (!request.path.endsWith(
            '/materials/make-short-1/supply-progress',
          )) {
            return null;
          }
          return {
            'materialLineId': 'make-short-1',
            'goodsCode': 'MAKE-SHORT',
            'goodsName': '自制短缺件',
            'route': 'MAKE',
            'steps': [
              {'key': 'MAKE_TASK', 'label': '已创建自制备料任务', 'state': 'DONE'},
              {
                'key': 'PLAN',
                'label': '生产计划',
                'state': 'DONE',
                'docNo': 'SJ-MAKE-DONE-001',
                'documentType': 'PRODUCTION_PLAN',
                'documentId': 'plan-make-done',
              },
              {'key': 'PRODUCTION', 'label': '生产完工入库', 'state': 'DONE'},
              {'key': 'STOCKED', 'label': '入库齐套', 'state': 'DONE'},
            ],
          };
        },
      );

      expect(
        find.byKey(const ValueKey('material-analysis-product-child-line-1')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('material-analysis-transferred-section')),
        findsNothing,
      );

      final makeRow = find.byKey(
        const ValueKey('material-bom-node-node-make-short-1'),
      );
      await tester.scrollUntilVisible(
        makeRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      for (final label in [
        '已转自制需求 8',
        '执行计划量 8',
        '已完工入库 8',
        '生产计划 · SJ-MAKE-DONE-001',
      ]) {
        expect(
          find.descendant(of: makeRow, matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
      }
      final workflow = find.descendant(
        of: makeRow,
        matching: find.byKey(
          const ValueKey('material-supply-progress-make-short-1'),
        ),
      );
      expect(workflow, findsOneWidget);
      await tester.tap(workflow);
      await tester.pumpAndSettle();

      expect(find.text('自制生产流程'), findsOneWidget);
      for (final step in ['已创建自制备料任务', '生产计划', '生产完工入库', '入库齐套']) {
        expect(find.text(step), findsOneWidget, reason: step);
      }
      expect(
        harness.requests.where(
          (request) =>
              request.path.endsWith('/materials/make-short-1/supply-progress'),
        ),
        hasLength(1),
      );

      final planLink = find.byKey(
        const ValueKey('supply-progress-document-PLAN'),
      );
      expect(planLink, findsOneWidget);
      await tester.tap(planLink);
      await tester.pumpAndSettle();
      expect(find.text('已打开计划 plan-make-done'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'MAKE child stays inline on its owner node and is not repeated as a BOM root',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final analysis = _makeChildBomRootAnalysisJson();
      analysis['allowedActions'] = const ['VIEW'];
      final child =
          (analysis['products'] as List<dynamic>).last as Map<String, dynamic>;
      child
        ..['submittedQty'] = 12
        ..['approvedQty'] = 0
        ..['remainingQty'] = 0
        ..['readyNowQty'] = 0
        ..['planExecutionStatus'] = 'COMPLETED'
        ..['latestPlanId'] = 'plan-make-child-done'
        ..['latestPlanNo'] = 'SJ-MAKE-CHILD-DONE'
        ..['planExecutionPlannedQty'] = 12
        ..['planExecutionInboundQty'] = 12
        ..['planExecutionProgressRatio'] = 1;
      final childMaterial =
          (analysis['flatMaterials'] as List<dynamic>).last
              as Map<String, dynamic>;
      childMaterial
        ..['requiredQty'] = 0
        ..['allocatedAvailableQty'] = 0
        ..['availableQty'] = 0
        ..['shortageQty'] = 0
        ..['demandSupplyGapQty'] = 0
        ..['requirementState'] = 'TRANSFERRED_TO_PLAN';

      await _pumpPage(
        tester,
        size: const Size(375, 900),
        permissions: const {
          Perm.productionMaterialAnalysisView,
          Perm.productionPlanView,
        },
        allowedActions: const ['VIEW'],
        analysisId: 'analysis-1',
        seeded: false,
        analysisJson: analysis,
        theme: ThemeData.dark(),
        textScale: 1.3,
      );

      expect(
        find.byKey(
          const ValueKey('material-bom-product-make-child-owner-12345678'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey('material-bom-node-node-make-child-own-material'),
        ),
        findsNothing,
      );

      final delegatedRow = find.byKey(
        const ValueKey('material-bom-node-node-delegated'),
      );
      await tester.scrollUntilVisible(
        delegatedRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(delegatedRow, findsOneWidget);
      expect(
        find.descendant(of: delegatedRow, matching: find.text('接管子任务状态 已完工入库')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
  testWidgets('completed MAKE plan deep link fails closed without permission', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(375, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
        Perm.productionMaterialAnalysisNotify,
      },
      analysisJson: _completedMakeAnalysisJson(),
      theme: ThemeData.dark(),
      textScale: 1.3,
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
      find.descendant(of: makeRow, matching: find.text('无查看生产计划权限')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: makeRow,
        matching: find.byKey(const ValueKey('material-view-plan-make-short-1')),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
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
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
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
      final batchField = find.byKey(const Key('batch-qty-product-line-1'));
      final batchLabel = find.byKey(
        const ValueKey('batch-qty-label-product-line-1'),
      );
      final batchHelper = find.byKey(
        const ValueKey('batch-qty-helper-product-line-1'),
      );
      final batchSemantics = find.byKey(
        const ValueKey('batch-qty-semantics-product-line-1'),
      );
      expect(
        find.descendant(of: firstProductCard, matching: batchLabel),
        findsOneWidget,
      );
      expect(
        find.descendant(of: firstProductCard, matching: batchHelper),
        findsOneWidget,
      );
      expect(tester.widget<Text>(batchLabel).style?.color, Colors.white);
      expect(tester.widget<Text>(batchHelper).style?.color, Colors.white70);
      expect(
        tester.getBottomRight(batchLabel).dy,
        lessThan(tester.getTopLeft(batchField).dy),
      );
      expect(
        tester.widget<Semantics>(batchSemantics).properties.label,
        '本批生产数量',
      );
      expect(
        tester.widget<TextField>(batchField).decoration?.labelText,
        isNull,
      );
      expect(tester.widget<TextField>(batchField).decoration?.helper, isNull);
      expect(tester.widget<TextField>(batchField).controller?.text, '4');
      expect(
        find.descendant(of: firstProductCard, matching: find.text('最多 4 个')),
        findsOneWidget,
      );
      await tester.enterText(batchField, '3');
      expect(find.text('生成总装计划(1)'), findsOneWidget);
      await tester.tap(find.text('生成总装计划(1)'));
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
      expect(
        find.byKey(const ValueKey('generated-plan-print-plan-1')),
        findsNothing,
      );
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

  testWidgets(
    'supply notify quantity defaults to residual and supports partial top-up',
    (tester) async {
      Map<String, dynamic> state({required bool partial}) {
        final json = _buySelectionAnalysisJson();
        if (partial) {
          final materials = (json['flatMaterials'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          final first = materials.firstWhere(
            (material) => material['materialLineId'] == 'buy-line-1',
          );
          // 服务端权威投影：在途 5（分摊量来自 preplan_supply_action_allocations）。
          first['downstreamReferences'] = [
            {
              'route': 'BUY',
              'status': 'CREATED',
              'documentType': 'PURCHASE_REQUEST',
              'documentId': 'purchase-request-1',
              'documentNo': 'CG-0001',
              'allocatedQty': 5,
            },
          ];
        }
        return json;
      }

      var notifyCalls = 0;
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        allowedActions: const ['NOTIFY_SUPPLY'],
        analysisJson: state(partial: false),
        responseOverride: (request) {
          if (!request.path.endsWith('/notify')) return null;
          notifyCalls++;
          return state(partial: true);
        },
      );

      final checkbox = find.byKey(
        const ValueKey('material-bom-select-buy-line-1'),
      );
      await tester.scrollUntilVisible(
        checkbox,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(checkbox);
      await tester.pump();
      await tester.tap(find.text('提交采购需求(1)'));
      await tester.pumpAndSettle();

      // 默认数量 = 本批需求缺口 8；改小成 5 实现分批。
      final qtyField = find.byKey(const Key('supply-qty-input-buy-action-1'));
      expect(find.textContaining('本批生产需求上限 8'), findsOneWidget);
      expect(tester.widget<TextFormField>(qtyField).controller?.text, '8');
      await tester.enterText(qtyField, '5');
      await tester.tap(find.byKey(const Key('supply-quantity-confirm')));
      await tester.pumpAndSettle();

      final first =
          harness.requests
                  .where((request) => request.path.endsWith('/notify'))
                  .first
                  .data!
              as Map<String, dynamic>;
      expect(first['quantities'], [
        {
          'actionGroupKey': 'buy-action-1',
          'qty': 5.0,
          'safetyReplenishmentQty': 0.0,
        },
      ]);

      // 需求在途 5、本批还差 3：行保持可勾选，操作列出现「继续提交」。
      final row = find.byKey(const ValueKey('material-bom-node-buy-node-1'));
      expect(
        find.descendant(of: row, matching: find.textContaining('需求在途 5')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('本批还差 3')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.byType(Checkbox)),
        findsOneWidget,
      );
      final topUp = find.byKey(const ValueKey('material-topup-buy-line-1'));
      await tester.scrollUntilVisible(
        topUp,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(topUp);
      await tester.pumpAndSettle();

      // 补交默认 = 剩余 3，直接确认。
      final topUpField = find.byKey(const Key('supply-qty-input-buy-action-1'));
      expect(find.textContaining('本批生产需求上限 3'), findsOneWidget);
      expect(find.textContaining('本批生产需求上限 3 个 · 需求在途 5 个'), findsOneWidget);
      expect(tester.widget<TextFormField>(topUpField).controller?.text, '3');
      await tester.tap(find.byKey(const Key('supply-quantity-confirm')));
      await tester.pumpAndSettle();

      final second =
          harness.requests
                  .where((request) => request.path.endsWith('/notify'))
                  .last
                  .data!
              as Map<String, dynamic>;
      expect(second['quantities'], [
        {
          'actionGroupKey': 'buy-action-1',
          'qty': 3.0,
          'safetyReplenishmentQty': 0.0,
        },
      ]);
      expect(notifyCalls, 2);
    },
  );

  testWidgets(
    'approve-now defaults on and shows both submission stages before result',
    (tester) async {
      final previewGate = Completer<void>();
      final generateGate = Completer<void>();
      final secondRound = _analysisJson(const [
        'PLAN_PREVIEW',
        'GENERATE_PLAN',
      ]);
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisGenerate,
          Perm.productionPlanApprove,
        },
        analysisJson: _analysisJson(const ['PLAN_PREVIEW', 'GENERATE_PLAN']),
        billDate: '2026-08-09',
        deliveryDate: '2026-08-12',
        departmentId: 'workshop-1',
        workshopName: '装配一车间',
        workerId: 'worker-1',
        responseOverride: (request) async {
          if (request.path.endsWith('/plan-preview')) {
            await previewGate.future;
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
                  'selectedQty': 4,
                  'canGenerate': true,
                },
              ],
            };
          }
          if (request.path.endsWith('/generate-plan')) {
            await generateGate.future;
            return {
              'analysis': secondRound,
              'plans': [
                {
                  'planId': 'plan-1',
                  'planNo': 'PP-20260809-001',
                  'status': 'APPROVED',
                  'packageId': 'package-1',
                  'segmentIds': ['segment-1'],
                  'drawIds': ['draw-1'],
                  'drawDocuments': [
                    {'drawId': 'draw-1', 'billNo': 'LL-20260809-001'},
                  ],
                },
              ],
            };
          }
          if (request.path.endsWith('/work-cards')) {
            return _confirmedWorkCardJson();
          }
          return null;
        },
      );

      await tester.tap(
        find.byKey(
          const ValueKey('material-analysis-product-select-product-line-1'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成总装计划(1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('汇总确认'));
      await tester.pumpAndSettle();

      // 有审核权限时才出现「生成后立即审核下达」。
      final approveNow = find.byKey(
        const Key('production-plan-wizard-approve-now'),
      );
      expect(approveNow, findsOneWidget);
      expect(tester.widget<CheckboxListTile>(approveNow).value, isTrue);
      expect(find.text('确认生成并审核下达'), findsOneWidget);
      await tester.tap(find.text('确认生成并审核下达'));

      // The wizard route closes first, then the parent page performs the
      // authoritative preview. Keep the request pending so the intermediate
      // state is observable and cannot regress to a blank page.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(
        find.byKey(const Key('material-analysis-plan-submission-progress')),
        findsOneWidget,
      );
      expect(find.text('正在校验最新库存与齐套状态'), findsOneWidget);
      expect(find.textContaining('第 1 / 2 步'), findsOneWidget);

      previewGate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      expect(
        find.byKey(const Key('material-analysis-plan-submission-progress')),
        findsOneWidget,
      );
      expect(find.text('正在生成并审核下达'), findsOneWidget);
      expect(find.textContaining('第 2 / 2 步'), findsOneWidget);
      expect(
        harness.requests.where(
          (request) => request.path.endsWith('/generate-plan'),
        ),
        hasLength(1),
      );

      generateGate.complete();
      await tester.pump();
      await tester.pumpAndSettle();

      final generate = harness.requests.singleWhere(
        (request) => request.path.endsWith('/generate-plan'),
      );
      expect((generate.data! as Map<String, dynamic>)['approveNow'], isTrue);

      // 同一屏摆出两张单据：生产计划单 + 物料提货单（领料单）。
      expect(find.text('计划单与提货单已生成'), findsOneWidget);
      expect(find.textContaining('PP-20260809-001'), findsOneWidget);
      expect(find.text('已审核下达'), findsOneWidget);
      expect(find.text('物料提货单(领料单)LL-20260809-001'), findsOneWidget);
      final printPlan = find.byKey(
        const ValueKey('generated-plan-print-plan-1'),
      );
      expect(printPlan, findsOneWidget);
      await tester.tap(printPlan);
      await tester.pumpAndSettle();

      expect(find.text('A4 生产计划单 · 流水线执行工卡'), findsOneWidget);
      expect(find.textContaining('SEG-001 · 测试产品'), findsOneWidget);
      expect(
        harness.requests.where(
          (request) => request.path.endsWith('/work-cards'),
        ),
        hasLength(1),
      );
      await tester.tap(find.byTooltip('关闭生产计划打印预览'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'plan preview failure clears submission overlay and never posts generate',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisGenerate,
          Perm.productionPlanApprove,
        },
        analysisJson: _analysisJson(const ['PLAN_PREVIEW', 'GENERATE_PLAN']),
        billDate: '2026-08-09',
        deliveryDate: '2026-08-12',
        departmentId: 'workshop-1',
        workshopName: '装配一车间',
        workerId: 'worker-1',
        errorOverride: (request) {
          if (!request.path.endsWith('/plan-preview')) return null;
          return DioException(
            requestOptions: request,
            type: DioExceptionType.badResponse,
            response: Response<dynamic>(
              requestOptions: request,
              statusCode: 500,
              data: const {'code': 'INTERNAL_ERROR', 'message': '计划预览服务暂时不可用'},
            ),
          );
        },
      );

      await tester.tap(
        find.byKey(
          const ValueKey('material-analysis-product-select-product-line-1'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成总装计划(1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('汇总确认'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('production-plan-wizard-approve-now')),
            )
            .value,
        isTrue,
      );

      await tester.tap(find.text('确认生成并审核下达'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('material-analysis-plan-submission-progress')),
        findsNothing,
      );
      expect(
        harness.requests.where(
          (request) => request.path.endsWith('/generate-plan'),
        ),
        isEmpty,
      );
      expect(
        find.byKey(const Key('material-analysis-generate')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'multi-plan result batches 51 printable plans and keeps later batch reachable',
    (tester) async {
      var failLastWorkCardOnce = true;
      final secondRound = _analysisJson(const [
        'PLAN_PREVIEW',
        'GENERATE_PLAN',
      ]);
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisGenerate,
          Perm.productionPlanApprove,
        },
        analysisJson: _analysisJson(const ['PLAN_PREVIEW', 'GENERATE_PLAN']),
        billDate: '2026-08-09',
        deliveryDate: '2026-08-12',
        departmentId: 'workshop-1',
        workshopName: '装配一车间',
        workerId: 'worker-1',
        errorOverride: (request) {
          if (failLastWorkCardOnce &&
              request.path.contains('/plans/plan-batch-50/') &&
              request.path.endsWith('/work-cards')) {
            failLastWorkCardOnce = false;
            return DioException(
              requestOptions: request,
              type: DioExceptionType.badResponse,
              response: Response<dynamic>(
                requestOptions: request,
                statusCode: 409,
                data: const {'code': 'CONFLICT', 'message': '确认计划包已变化'},
              ),
            );
          }
          return null;
        },
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
                  'selectedQty': 4,
                  'canGenerate': true,
                },
              ],
            };
          }
          if (request.path.endsWith('/generate-plan')) {
            return {
              'analysis': secondRound,
              'plans': [
                for (var index = 0; index < 51; index++)
                  {
                    'planId': 'plan-batch-$index',
                    'planNo': 'PP-BATCH-${index.toString().padLeft(3, '0')}',
                    'status': 'APPROVED',
                    'packageId': 'package-batch-$index',
                    'segmentIds': ['segment-batch-$index'],
                  },
                {
                  'planId': 'plan-draft',
                  'planNo': 'PP-DRAFT',
                  'status': 'DRAFT',
                },
                {
                  'planId': 'plan-missing-package',
                  'planNo': 'PP-MISSING',
                  'status': 'APPROVED',
                },
              ],
            };
          }
          if (request.path.endsWith('/work-cards')) {
            final parts = request.path.split('/');
            final planId = parts[3];
            final packageId = parts[5];
            final index = int.parse(planId.split('-').last);
            return _confirmedWorkCardJson(
              planId: planId,
              planBillNo: 'PP-BATCH-${index.toString().padLeft(3, '0')}',
              packageId: packageId,
              segmentId: 'segment-batch-$index',
              segmentCode: 'SEG-BATCH-${index.toString().padLeft(3, '0')}',
            );
          }
          return null;
        },
      );

      await tester.tap(
        find.byKey(
          const ValueKey('material-analysis-product-select-product-line-1'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成总装计划(1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('汇总确认'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认生成并审核下达'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('generated-plan-print-plan-draft')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('generated-plan-print-plan-missing-package')),
        findsNothing,
      );
      expect(find.textContaining('1 张待审核不包含'), findsOneWidget);
      expect(find.textContaining('1 张缺确认包不包含'), findsOneWidget);

      final firstBatch = find.byKey(
        const ValueKey('generated-plans-print-batch-0'),
      );
      await tester.ensureVisible(firstBatch);
      await tester.tap(firstBatch);
      await tester.pumpAndSettle();
      expect(find.textContaining('50 张生产计划 · 50 张执行工卡'), findsOneWidget);
      expect(
        harness.requests.where(
          (request) => request.path.endsWith('/work-cards'),
        ),
        hasLength(50),
      );

      await tester.tap(find.byTooltip('关闭生产计划打印预览'));
      await tester.pumpAndSettle();
      final secondBatch = find.byKey(
        const ValueKey('generated-plans-print-batch-1'),
      );
      expect(secondBatch, findsOneWidget);
      await tester.ensureVisible(secondBatch);
      await tester.tap(secondBatch);
      await tester.pumpAndSettle();
      expect(find.textContaining('生产计划 PP-BATCH-050：确认计划包已变化'), findsOneWidget);
      expect(
        harness.requests.where(
          (request) => request.path.endsWith('/work-cards'),
        ),
        hasLength(51),
      );
      await tester.tap(find.text('重新读取'));
      await tester.pumpAndSettle();
      expect(find.textContaining('PP-BATCH-050 · 1 张执行工卡'), findsOneWidget);
      expect(
        harness.requests.where(
          (request) => request.path.endsWith('/work-cards'),
        ),
        hasLength(52),
      );

      await tester.tap(find.byTooltip('关闭生产计划打印预览'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('留在物料分析'));
      await tester.tap(find.text('留在物料分析'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'product cards show kitting progress bar and shortage kind summary',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
      );

      final firstCard = find.byKey(
        const ValueKey('material-analysis-product-product-line-1'),
      );
      expect(
        find.descendant(
          of: firstCard,
          matching: find.byKey(
            const ValueKey('material-analysis-product-progress-product-line-1'),
          ),
        ),
        findsOneWidget,
      );
      // 测试产品下有 2 种缺料、3 条路径(共享紧固件×2 + 下层依赖件)，路线均未确认。
      expect(
        find.descendant(
          of: firstCard,
          matching: find.textContaining(
            '还缺 2 种物料 · 共 3 条 BOM 路径 · 其中 3 条路线待确认',
          ),
        ),
        findsOneWidget,
      );
      // 第二产品没有缺料路径，不显示缺口摘要。
      final secondCard = find.byKey(
        const ValueKey('material-analysis-product-product-line-2'),
      );
      expect(
        find.descendant(of: secondCard, matching: find.textContaining('还缺')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'BOM node rows show coverage inline and reveal numbers from the rail bar',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
      );
      final firstRow = find.byKey(
        const ValueKey('material-bom-node-material-path-1'),
      );
      await tester.scrollUntilVisible(
        firstRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      // 本批覆盖只认 max(已分配 3, exact 0)，安全/在途不混成本批已到：3/16=19%。
      expect(
        find.descendant(of: firstRow, matching: find.text('合格库存保障 3/16(19%)')),
        findsOneWidget,
      );
      // 左侧竖向进度条：点按浮出数字，点其它位置消失。
      final rail = find.byKey(
        const ValueKey('material-node-rail-progress-material-path-1'),
      );
      final fill = find.byKey(
        const ValueKey('material-node-rail-fill-material-path-1'),
      );
      final fillDecoration =
          tester.widget<DecoratedBox>(fill).decoration as BoxDecoration;
      final fillGradient = fillDecoration.gradient! as LinearGradient;
      expect(tester.getSize(fill).width, greaterThanOrEqualTo(8));
      expect(tester.getSize(fill).height, greaterThan(0));
      expect(fillGradient.begin, Alignment.bottomCenter);
      expect(fillGradient.end, Alignment.topCenter);
      expect(fillGradient.stops![1], closeTo(3 / 16, 0.0001));
      expect(fillGradient.stops![2], closeTo(3 / 16, 0.0001));
      await tester.tap(rail);
      await tester.pumpAndSettle();
      final peek = find.byKey(
        const ValueKey('material-node-progress-peek-material-path-1'),
      );
      expect(peek, findsOneWidget);
      expect(
        find.descendant(of: peek, matching: find.text('合格库存保障 3/16(19%)')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('material-bom-node-material-path-2')),
      );
      await tester.pumpAndSettle();
      expect(peek, findsNothing);
    },
  );

  testWidgets('compact material rails preserve exact 0 and 5 percent fill', (
    tester,
  ) async {
    final json = _analysisJson(const ['VIEW']);
    final materials = (json['flatMaterials'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    materials[0]
      ..['requiredQty'] = 100
      ..['allocatedAvailableQty'] = 5
      ..['exactPeggedQty'] = 0
      ..['shortageQty'] = 95;
    materials[1]
      ..['requiredQty'] = 100
      ..['allocatedAvailableQty'] = 0
      ..['exactPeggedQty'] = 0
      ..['shortageQty'] = 100;
    await _pumpPage(
      tester,
      size: const Size(375, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
      },
      allowedActions: const ['VIEW'],
      analysisJson: json,
    );

    final fivePercent = find.byKey(
      const ValueKey('material-node-rail-fill-material-path-1'),
    );
    await tester.scrollUntilVisible(
      fivePercent,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final fiveDecoration =
        tester.widget<DecoratedBox>(fivePercent).decoration as BoxDecoration;
    final fiveGradient = fiveDecoration.gradient! as LinearGradient;
    expect(fiveGradient.stops![1], closeTo(0.05, 0.0001));
    expect(fiveGradient.stops![2], closeTo(0.05, 0.0001));
    expect(tester.getSize(fivePercent).height, greaterThan(0));

    final zeroPercent = find.byKey(
      const ValueKey('material-node-rail-fill-material-path-2'),
    );
    await tester.scrollUntilVisible(
      zeroPercent,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final zeroDecoration =
        tester.widget<DecoratedBox>(zeroPercent).decoration as BoxDecoration;
    expect(zeroDecoration.gradient, isNull);
    expect(zeroDecoration.color, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'material aggregate view merges shared material across products and keeps per-path selection',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _aggregateAnalysisJson(),
      );

      final layoutToggle = find.byKey(
        const ValueKey('material-bom-layout-material'),
      );
      await tester.scrollUntilVisible(
        layoutToggle,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(layoutToggle);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('material-aggregate-list')), findsOneWidget);
      // 同一物料跨两个产品、两条路径聚成一行：需求和合格库存保障加总，
      // 公共现货取共享池快照（各路径同源，不重复计数）。
      final sharedRow = find.byKey(
        const ValueKey('material-aggregate-goods-shared-motor||个'),
      );
      expect(sharedRow, findsOneWidget);
      expect(
        find.descendant(of: sharedRow, matching: find.text('本批总需求 15')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sharedRow, matching: find.text('公共现货 4')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sharedRow, matching: find.text('合格库存保障 4/15(27%)')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sharedRow, matching: find.text('2 个产品路径')),
        findsOneWidget,
      );
      // 展开前不渲染逐路径明细。
      expect(
        find.byKey(const ValueKey('material-aggregate-path-agg-path-1')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(
          const ValueKey('material-aggregate-toggle-goods-shared-motor||个'),
        ),
      );
      await tester.pumpAndSettle();
      final firstPath = find.byKey(
        const ValueKey('material-aggregate-path-agg-path-1'),
      );
      final secondPath = find.byKey(
        const ValueKey('material-aggregate-path-agg-path-2'),
      );
      expect(firstPath, findsOneWidget);
      expect(secondPath, findsOneWidget);
      expect(
        find.descendant(of: firstPath, matching: find.text('测试产品')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: secondPath, matching: find.text('第二测试产品')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: firstPath, matching: find.text('合格库存保障 4/10(40%)')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: secondPath, matching: find.text('合格库存保障 0/5(0%)')),
        findsOneWidget,
      );

      // 勾选两条路径 → 底部按路线汇总为一次采购提交；任务身份仍逐路径独立。
      // 展开后的路径行可能位于视口下方，先滚动到可见再点选。
      final firstSelect = find.byKey(
        const ValueKey('material-bom-select-agg-path-1'),
      );
      await tester.scrollUntilVisible(
        firstSelect,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(firstSelect);
      await tester.pumpAndSettle();
      final secondSelect = find.byKey(
        const ValueKey('material-bom-select-agg-path-2'),
      );
      await tester.scrollUntilVisible(
        secondSelect,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(secondSelect);
      await tester.pumpAndSettle();
      expect(find.text('提交采购需求(2)'), findsOneWidget);
    },
  );

  testWidgets(
    'borrow moves stock coverage between products with dual visibility',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisReallocate,
        },
        analysisJson: _aggregateAnalysisJson(),
        responseOverride: (request) {
          if (request.path.endsWith('/borrows')) {
            return _borrowedAnalysisJson();
          }
          return null;
        },
      );

      // 打开借出节点（测试产品 · 共享电机）的详情，进入调拨对话框。
      final firstRow = find.byKey(
        const ValueKey('material-bom-node-agg-node-1'),
      );
      await tester.scrollUntilVisible(
        firstRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      final details = find.byKey(
        const ValueKey('material-node-details-toggle-agg-path-1'),
      );
      expect(details, findsOneWidget);
      await tester.tap(details);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('material-borrow-start-agg-path-1')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('material-borrow-dialog')), findsOneWidget);
      expect(find.textContaining('跨计划让料'), findsOneWidget);
      expect(find.textContaining('优先待补'), findsOneWidget);
      expect(find.textContaining('接受计划无需返还'), findsOneWidget);
      // 只列出其它产品中缺同种料的路径（第二测试产品 · 共享电机）。
      await tester.tap(
        find.byKey(const ValueKey('material-borrow-target-agg-path-2')),
      );
      await tester.pumpAndSettle();
      // 默认值先行：数量预填 min(借出已分配 4, 对方缺口 5) = 4。
      expect(
        find.descendant(
          of: find.byKey(const Key('material-borrow-qty')),
          matching: find.text('4'),
        ),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('material-borrow-reason')),
        '客户加急，先保这单',
      );
      await tester.pumpAndSettle();
      // 确认前必须看到双方影响的大白话提示。
      expect(find.textContaining('会重新缺 4 件该料'), findsOneWidget);
      await tester.tap(find.byKey(const Key('material-borrow-confirm')));
      await tester.pumpAndSettle();

      final borrowRequest = harness.requests.singleWhere(
        (request) => request.path.endsWith('/borrows'),
      );
      final body = borrowRequest.data! as Map<String, dynamic>;
      expect(body['fromMaterialLineId'], 'agg-path-1');
      expect(body['toMaterialLineId'], 'agg-path-2');
      expect(body['qty'], 4.0);
      expect(body['reason'], '客户加急，先保这单');

      // 服务端重算后：借出方行显示"已被调走 · 调给 第二测试产品"，
      // 借入方行（在第二产品的 BOM 区，需滚动到可见）显示"已调入 · 来自 测试产品"。
      expect(find.text('已被调走 4 件 · 调给 第二测试产品'), findsOneWidget);
      final secondRow = find.byKey(
        const ValueKey('material-bom-node-agg-node-2'),
      );
      await tester.scrollUntilVisible(
        secondRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('已调入 4 件 · 来自 测试产品'), findsOneWidget);
    },
  );

  testWidgets('active borrow can be revoked with an audited reason', (
    tester,
  ) async {
    final harness = await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
        Perm.productionMaterialAnalysisReallocate,
      },
      analysisJson: _borrowedAnalysisJson(),
      responseOverride: (request) {
        if (request.path.endsWith('/revoke')) {
          return _aggregateAnalysisJson();
        }
        return null;
      },
    );

    // 借出方详情里能看到逐笔明细并撤销。
    final fromRow = find.byKey(const ValueKey('material-bom-node-agg-node-1'));
    await tester.scrollUntilVisible(
      fromRow,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final details = find.byKey(
      const ValueKey('material-node-details-toggle-agg-path-1'),
    );
    expect(details, findsOneWidget);
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.textContaining('借出 4 件 · 调给 第二测试产品'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('material-borrow-revoke-borrow-1')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('borrow-revoke-reason')),
      '对方那单延期了，先撤回来',
    );
    await tester.tap(find.text('确认撤销'));
    await tester.pumpAndSettle();

    final revokeRequest = harness.requests.singleWhere(
      (request) => request.path.endsWith('/borrows/borrow-1/revoke'),
    );
    final body = revokeRequest.data! as Map<String, dynamic>;
    expect(body['reason'], '对方那单延期了，先撤回来');
    // 撤销后刷新视图：双向徽标消失。
    expect(find.textContaining('已被调走'), findsNothing);
    expect(find.textContaining('已调入'), findsNothing);
  });

  testWidgets(
    'empty server allowedActions fail closed despite local permission',
    (tester) async {
      final analysisJson = _borrowedAnalysisJson()
        ..['allowedActions'] = const <String>[];
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        // manage 只是让预览发生；借用入口的服务端门禁才是本用例验证点。
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisReallocate,
        },
        analysisJson: analysisJson,
      );

      final fromRow = find.byKey(
        const ValueKey('material-bom-node-agg-node-1'),
      );
      await tester.scrollUntilVisible(
        fromRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(
        find.byKey(const ValueKey('material-node-details-toggle-agg-path-1')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('material-borrow-revoke-borrow-1')),
        findsNothing,
      );

      final toRow = find.byKey(const ValueKey('material-bom-node-agg-node-2'));
      await tester.scrollUntilVisible(
        toRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(
        find.byKey(const ValueKey('material-node-details-toggle-agg-path-2')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('material-borrow-start-agg-path-2')),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey('material-cross-reallocation-start-agg-path-2'),
        ),
        findsNothing,
      );
      expect(
        harness.requests.where(
          (request) =>
              request.path.endsWith('/borrows') ||
              request.path.contains('/borrows/') ||
              request.path.contains('/cross-reallocations'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets(
    'source plan shows priority pending, replenishment source and revoke block',
    (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisReallocate,
        },
        analysisJson: _crossReallocatedAnalysisJson(),
      );

      final row = find.byKey(const ValueKey('material-bom-node-agg-node-1'));
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('优先待补 2 件'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('material-node-details-toggle-agg-path-1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('补齐来源'), findsOneWidget);
      expect(find.textContaining('采购入库 2'), findsOneWidget);
      expect(find.textContaining('接受计划已领料'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('material-cross-reallocation-revoke-cross-1'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('target plan shows accepted quantity and no-return meaning', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
        Perm.productionMaterialAnalysisReallocate,
      },
      analysisJson: _crossReallocatedAnalysisJson(inbound: true),
    );

    final row = find.byKey(const ValueKey('material-bom-node-agg-node-1'));
    await tester.scrollUntilVisible(
      row,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('已接受 4 件'), findsOneWidget);
    expect(find.textContaining('无需返还'), findsOneWidget);
  });

  testWidgets('REVERSED reallocation shows restored terminal meaning', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
      },
      analysisJson: _crossReallocatedAnalysisJson(
        status: 'REVERSED',
        currentEffectiveQty: 0,
      ),
    );

    await _openAggregateMaterialDetails(tester);
    expect(find.textContaining('跨计划让料已撤销'), findsWidgets);
    expect(find.textContaining('权益已恢复'), findsWidgets);
    expect(find.textContaining('双方当前权益已按事件恢复'), findsOneWidget);
    expect(find.textContaining('优先待补 2 件'), findsNothing);
  });

  testWidgets('CANCELLED reallocation projects remaining beneficiary slice', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
      },
      analysisJson: _crossReallocatedAnalysisJson(
        inbound: true,
        status: 'CANCELLED',
      ),
    );

    await _openAggregateMaterialDetails(tester);
    expect(find.textContaining('当前仍保留 4 件'), findsOneWidget);
    expect(find.textContaining('当前保留 4 件'), findsOneWidget);
    expect(find.textContaining('继续保留给本计划'), findsOneWidget);
  });

  testWidgets('CANCELLED reallocation shows released beneficiary slice', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
      },
      analysisJson: _crossReallocatedAnalysisJson(
        status: 'CANCELLED',
        currentEffectiveQty: 0,
      ),
    );

    await _openAggregateMaterialDetails(tester);
    expect(find.textContaining('当前权益已释放'), findsWidgets);
    expect(find.textContaining('记录仅保留用于审计'), findsOneWidget);
  });
  testWidgets('cross-plan entry has independent local and server permissions', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
        Perm.productionMaterialAnalysisReallocate,
      },
      analysisJson: _aggregateAnalysisJson(),
    );
    await _openAggregateMaterialDetails(tester);
    expect(
      find.byKey(const ValueKey('material-borrow-start-agg-path-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('material-cross-reallocation-start-agg-path-1'),
      ),
      findsNothing,
      reason: '旧 REALLOCATE 不能隐式开启跨计划让料',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    final crossAllowed = _aggregateAnalysisJson()
      ..['allowedActions'] = const ['CROSS_REALLOCATE'];
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
        Perm.productionMaterialAnalysisCrossReallocate,
      },
      analysisJson: crossAllowed,
    );
    await _openAggregateMaterialDetails(tester);
    expect(
      find.byKey(const ValueKey('material-borrow-start-agg-path-1')),
      findsNothing,
    );
    final crossEntry = find.byKey(
      const ValueKey('material-cross-reallocation-start-agg-path-1'),
    );
    await tester.scrollUntilVisible(
      crossEntry,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(crossEntry, findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    final serverDenied = _aggregateAnalysisJson()
      ..['allowedActions'] = const ['REALLOCATE'];
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
        Perm.productionMaterialAnalysisCrossReallocate,
      },
      analysisJson: serverDenied,
    );
    await _openAggregateMaterialDetails(tester);
    expect(
      find.byKey(
        const ValueKey('material-cross-reallocation-start-agg-path-1'),
      ),
      findsNothing,
      reason: '服务端动作缺失时跨计划入口必须 fail closed',
    );
  });

  testWidgets(
    'cross-plan revoke has independent local and server permissions',
    (tester) async {
      final crossAllowed = _crossReallocatableAnalysisJson(const [
        'CROSS_REALLOCATE',
      ]);
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisCrossReallocate,
        },
        analysisJson: crossAllowed,
      );
      await _openAggregateMaterialDetails(tester);
      expect(
        find.byKey(
          const ValueKey('material-cross-reallocation-revoke-cross-1'),
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisReallocate,
        },
        analysisJson: _crossReallocatableAnalysisJson(const [
          'CROSS_REALLOCATE',
        ]),
      );
      await _openAggregateMaterialDetails(tester);
      expect(
        find.byKey(
          const ValueKey('material-cross-reallocation-revoke-cross-1'),
        ),
        findsNothing,
        reason: '旧 REALLOCATE 不能撤销跨计划让料',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisCrossReallocate,
        },
        analysisJson: _crossReallocatableAnalysisJson(const ['REALLOCATE']),
      );
      await _openAggregateMaterialDetails(tester);
      expect(
        find.byKey(
          const ValueKey('material-cross-reallocation-revoke-cross-1'),
        ),
        findsNothing,
        reason: '服务端未授予 CROSS_REALLOCATE 时撤销也必须 fail closed',
      );
    },
  );

  testWidgets(
    'positive demand keeps a genuine zero qualified-stock coverage in every view',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        analysisJson: _requirementStateAnalysisJson(),
      );

      final row = find.byKey(
        const ValueKey('material-bom-node-node-active-zero'),
      );
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: row, matching: find.text('本批需求 10')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('合格库存保障 0/10(0%)')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('本批已保障')),
        findsNothing,
      );
      expect(find.bySemanticsLabel('合格库存保障 0/10(0%)'), findsWidgets);

      await tester.tap(
        find.byKey(const ValueKey('material-node-details-toggle-active-zero')),
      );
      await tester.pumpAndSettle();
      final details = find.byKey(
        const ValueKey('material-node-details-active-zero'),
      );
      expect(
        find.descendant(of: details, matching: find.text('合格库存保障 0/10(0%)')),
        findsOneWidget,
      );

      final layoutToggle = find.byKey(
        const ValueKey('material-bom-layout-material'),
      );
      await tester.scrollUntilVisible(
        layoutToggle,
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(layoutToggle);
      await tester.pumpAndSettle();
      await tester.tap(layoutToggle);
      await tester.pumpAndSettle();
      final aggregate = find.byKey(
        const ValueKey('material-aggregate-goods-active-zero||个'),
      );
      await tester.scrollUntilVisible(
        aggregate,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(aggregate);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: aggregate, matching: find.text('合格库存保障 0/10(0%)')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(
          const ValueKey('material-aggregate-toggle-goods-active-zero||个'),
        ),
      );
      await tester.pumpAndSettle();
      final path = find.byKey(
        const ValueKey('material-aggregate-path-active-zero'),
      );
      // 详情展开状态跨布局保留：逐路径摘要与展开详情各显示一次同一保障事实。
      expect(
        find.descendant(of: path, matching: find.text('合格库存保障 0/10(0%)')),
        findsNWidgets(2),
      );
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'MAKE execution separates transferred planned inbound and stock coverage',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await _pumpPage(
        tester,
        size: const Size(375, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _makeExecutionProjectionJson(),
        theme: ThemeData.dark(),
        textScale: 1.3,
      );

      final row = find.byKey(
        const ValueKey('material-bom-node-node-make-short-1'),
      );
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      for (final label in [
        '本批需求 10',
        '合格库存保障 0/10(0%)',
        '已转自制需求 10',
        '执行计划量 10',
        '已完工入库 0',
        '生产执行中 0% · 尚未完工入库',
      ]) {
        expect(
          find.descendant(of: row, matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
      }
      expect(find.bySemanticsLabel('生产执行中 0% · 尚未完工入库'), findsWidgets);
      final zeroProgressPanel = find.byKey(
        const ValueKey('material-analysis-product-execution-child-line-1'),
      );
      final zeroProgressFill = find.byKey(
        const ValueKey('material-analysis-product-execution-fill-child-line-1'),
      );
      expect(zeroProgressPanel, findsOneWidget);
      expect(zeroProgressFill, findsOneWidget);
      expect(tester.getSize(zeroProgressFill).width, 0);
      expect(
        find.descendant(of: row, matching: find.textContaining('本批已保障')),
        findsNothing,
      );
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'covered stock never fabricates MAKE completion while child is running',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _makeExecutionProjectionJson(inventoryCovered: true),
      );

      final row = find.byKey(
        const ValueKey('material-bom-node-node-make-short-1'),
      );
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: row, matching: find.text('合格库存保障 10/10(100%)')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text('本批库存已覆盖 · 生产执行中 0% · 尚未完工入库'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('备货完成')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'delegated path hides zero noise and keeps readable owner in all layouts',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await _pumpPage(
        tester,
        size: const Size(375, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        analysisJson: _requirementStateAnalysisJson(),
        theme: ThemeData.dark(),
        textScale: 1.3,
      );

      final row = find.byKey(
        const ValueKey('material-bom-node-node-delegated'),
      );
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      for (final label in [
        '需求已转交自制子任务',
        '本节点不再重复备料',
        '接管子任务总需求 12',
        '接管来源 自制备料 2026-08-30 abcd',
        '接管子任务状态 生产执行中 0% · 尚未完工入库',
      ]) {
        expect(
          find.descendant(of: row, matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
      }
      for (final noise in ['本批需求 0', '合格库存保障 0/0(0%)', '公共可用 0', '公共补库在途 0']) {
        expect(
          find.descendant(of: row, matching: find.text(noise)),
          findsNothing,
          reason: noise,
        );
      }
      expect(find.bySemanticsLabel('需求已转交自制子任务。本节点不再重复备料'), findsWidgets);

      final detailsToggle = find.byKey(
        const ValueKey('material-node-details-toggle-delegated'),
      );
      await tester.ensureVisible(detailsToggle);
      await tester.pumpAndSettle();
      await tester.tap(detailsToggle);
      await tester.pumpAndSettle();
      final details = find.byKey(
        const ValueKey('material-node-details-delegated'),
      );
      expect(
        find.descendant(
          of: details,
          matching: find.text('接管来源 自制备料 2026-08-30 abcd'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: details, matching: find.text('公共可用 0')),
        findsNothing,
      );

      final layoutToggle = find.byKey(
        const ValueKey('material-bom-layout-material'),
      );
      await tester.scrollUntilVisible(
        layoutToggle,
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(layoutToggle);
      await tester.pumpAndSettle();
      await tester.tap(layoutToggle);
      await tester.pumpAndSettle();
      final aggregate = find.byKey(
        const ValueKey('material-aggregate-goods-delegated||个'),
      );
      await tester.scrollUntilVisible(
        aggregate,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(aggregate);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: aggregate,
          matching: find.text('当前无激活需求，展开查看各路径原因'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: aggregate, matching: find.text('公共现货 0')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(
          const ValueKey('material-aggregate-toggle-goods-delegated||个'),
        ),
      );
      await tester.pumpAndSettle();
      final path = find.byKey(
        const ValueKey('material-aggregate-path-delegated'),
      );
      // 详情展开状态跨布局保留：逐路径摘要与展开详情各显示一次接管来源。
      expect(
        find.descendant(
          of: path,
          matching: find.text('接管来源 自制备料 2026-08-30 abcd'),
        ),
        findsNWidgets(2),
      );
      expect(
        find.descendant(
          of: path,
          matching: find.text('接管子任务状态 生产执行中 0% · 尚未完工入库'),
        ),
        findsNWidgets(2),
      );
      expect(
        find.descendant(of: path, matching: find.text('本批需求 0')),
        findsNothing,
      );
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inactive requirement states expose distinct cause and recovery text',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        analysisJson: _requirementStateAnalysisJson(),
      );

      const expectations = {
        'parent-covered': ('上级件已由合格库存覆盖', '本节点本批不激活；上级出现新缺口后会自动重算'),
        'parent-route': ('上级路线不展开本节点', '若上级改为自制或供料委外，刷新后会重新计算'),
        'reference': ('参考节点，不形成本批备料需求', '如需参与生产备料，请核对 BOM 控制阶段'),
        'transferred': ('本批需求已转入生产计划', '请从关联生产计划继续跟踪领料与执行'),
        'inactive': ('本批需求未激活', '刷新后仍无需求时，请核对上级路线和 BOM'),
      };
      for (final entry in expectations.entries) {
        final row = find.byKey(ValueKey('material-bom-node-node-${entry.key}'));
        await tester.scrollUntilVisible(
          row,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          find.descendant(of: row, matching: find.text(entry.value.$1)),
          findsOneWidget,
          reason: entry.key,
        );
        expect(
          find.descendant(of: row, matching: find.text(entry.value.$2)),
          findsOneWidget,
          reason: entry.key,
        );
      }
      expect(find.text('本批无需补货'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'created MAKE child without plan facts says no plan instead of data pending',
    (tester) async {
      final analysis = _makeReadyChildAnalysisJson();
      (analysis['flatMaterials'] as List<dynamic>).add({
        ..._routeMaterial(
          id: 'make-ready-child-material',
          nodeKey: 'node-make-ready-child-material',
          actionGroupKey: 'action-make-ready-child-material',
          goodsCode: 'MAKE-READY-MAT',
          goodsName: '已齐套子任务原料',
          route: 'BUY',
          controlStage: 'START',
        ),
        'analysisLineId': 'make-child-ready-1',
        'requiredQty': 4,
        'allocatedAvailableQty': 4,
        'availableQty': 4,
        'shortageQty': 0,
        'demandSupplyGapQty': 0,
        'actionable': false,
      });
      (analysis['products'] as List<dynamic>).add({
        'analysisLineId': 'make-child-blocked-1',
        'sourceType': 'MAKE_COMPONENT',
        'parentAnalysisLineId': 'product-line-1',
        'parentGoodsName': '测试产品',
        'goodsId': 'goods-make-child-blocked-1',
        'goodsCode': 'MAKE-BLOCKED',
        'goodsName': '待下层备料自制子任务',
        'unitName': '个',
        'requestedQty': 5,
        'submittedQty': 0,
        'approvedQty': 0,
        'remainingQty': 5,
        'readyNowQty': 0,
        'readinessRatio': 0,
        'hasProductionMaterialChildren': true,
        'allocationPriority': 4,
      });
      (analysis['flatMaterials'] as List<dynamic>).add({
        ..._routeMaterial(
          id: 'make-blocked-child-material',
          nodeKey: 'node-make-blocked-child-material',
          actionGroupKey: 'action-make-blocked-child-material',
          goodsCode: 'MAKE-BLOCKED-MAT',
          goodsName: '待备子任务原料',
          route: 'BUY',
          controlStage: 'START',
        ),
        'analysisLineId': 'make-child-blocked-1',
        'requiredQty': 5,
        'allocatedAvailableQty': 0,
        'availableQty': 0,
        'shortageQty': 5,
        'demandSupplyGapQty': 5,
        'actionable': false,
      });
      await _pumpPage(
        tester,
        size: const Size(375, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: analysis,
        theme: ThemeData.dark(),
        textScale: 1.3,
      );

      final row = find.byKey(const ValueKey('material-bom-node-node-make-1'));
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: row, matching: find.text('已转自制需求 8')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('自制子任务已创建 · 尚未生成生产计划')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('执行计划量')),
        findsNothing,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('已完工入库')),
        findsNothing,
      );
      expect(
        find.descendant(of: row, matching: find.text('待安排生产')),
        findsOneWidget,
      );
      final childRoot = find.byKey(
        const ValueKey('material-bom-product-make-child-ready-1'),
      );
      expect(childRoot, findsNothing);
      final blockedChildRoot = find.byKey(
        const ValueKey('material-bom-product-make-child-blocked-1'),
      );
      expect(blockedChildRoot, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same-goods MAKE paths never borrow a child without an exact child id',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _sameGoodsMakePathAnalysisJson(),
      );

      final exactRow = find.byKey(
        const ValueKey('material-bom-node-node-make-exact'),
      );
      await tester.scrollUntilVisible(
        exactRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: exactRow, matching: find.text('生产执行中 20%')),
        findsOneWidget,
      );

      final missingIdRow = find.byKey(
        const ValueKey('material-bom-node-node-make-missing-id'),
      );
      await tester.scrollUntilVisible(
        missingIdRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: missingIdRow, matching: find.text('待安排生产')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: missingIdRow,
          matching: find.textContaining('生产执行中'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: missingIdRow,
          matching: find.textContaining('执行计划量'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _openAggregateMaterialDetails(WidgetTester tester) async {
  final row = find.byKey(const ValueKey('material-bom-node-agg-node-1'));
  await tester.scrollUntilVisible(
    row,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(
    find.byKey(const ValueKey('material-node-details-toggle-agg-path-1')),
  );
  await tester.pumpAndSettle();
}

Future<void> _chooseRoute(WidgetTester tester, String label) async {
  // 路线操作在节点右操作区（不在详情里）：点「更换路线/选择路线」弹出路线面板。
  var button = find.byKey(
    const ValueKey('material-route-change-material-path-1'),
  );
  if (button.evaluate().isEmpty) {
    button = find.byKey(const ValueKey('material-route-pick-material-path-1'));
  }
  await tester.scrollUntilVisible(
    button,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
  // 路线面板（底部弹层）：点选目标路线；偏离建议会再弹覆盖原因对话框。
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
  DioException? Function(RequestOptions request)? errorOverride,
  FutureOr<Map<String, dynamic>?> Function(RequestOptions request)?
  responseOverride,
  String? billDate,
  String? deliveryDate,
  String? departmentId,
  String? workshopName,
  String? workerId,
  ThemeData? theme,
  double textScale = 1,
  bool withPlanRoute = false,
  bool withSubcontractPreparationRoute = false,
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
    errorOverride: errorOverride,
    responseOverride: responseOverride,
  );
  final page = ProductionMaterialAnalysisPage(
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
  );
  final TransitionBuilder? mediaBuilder = textScale == 1
      ? null
      : (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        );
  final GoRouter? router = withPlanRoute || withSubcontractPreparationRoute
      ? GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => page),
            if (withPlanRoute)
              GoRoute(
                path: '/production/plans/:id',
                builder: (_, state) =>
                    Scaffold(body: Text('已打开计划 ${state.pathParameters['id']}')),
              ),
            if (withSubcontractPreparationRoute)
              GoRoute(
                path: '/subcontract/preparations',
                builder: (_, state) => Scaffold(
                  body: Text(
                    'prep-${state.uri.queryParameters['sourceAnalysisId']}-'
                    '${state.uri.queryParameters['sourceMaterialLineId']}',
                  ),
                ),
              ),
          ],
        )
      : null;
  if (router != null) addTearDown(router.dispose);
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
        productionWorkshopTreeProvider.overrideWith(
          (ref) async => _productionWorkshops(),
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: router == null
          ? MaterialApp(theme: theme, builder: mediaBuilder, home: page)
          : MaterialApp.router(
              theme: theme,
              builder: mediaBuilder,
              routerConfig: router,
            ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return _Harness(requests);
}

List<DepartmentNode> _productionWorkshops() => [
  DepartmentNode(
    id: 'workshop-1',
    code: 'WS_ASSEMBLY_1',
    name: '装配一车间',
    level: '一级部门',
    children: const [],
  ),
];

DioException _materialAnalysisConflict(RequestOptions request) => DioException(
  requestOptions: request,
  type: DioExceptionType.badResponse,
  response: Response<dynamic>(
    requestOptions: request,
    statusCode: 409,
    data: {'code': 'CONFLICT', 'message': '物料分析已被刷新或修改，请重新加载'},
  ),
);

ApiClient _api(
  List<RequestOptions> requests,
  List<String> allowedActions, {
  Map<String, dynamic>? analysisJson,
  DioException? Function(RequestOptions request)? errorOverride,
  FutureOr<Map<String, dynamic>?> Function(RequestOptions request)?
  responseOverride,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) async {
        requests.add(request);
        final failure = errorOverride?.call(request);
        if (failure != null) {
          handler.reject(failure);
          return;
        }
        final custom = await responseOverride?.call(request);
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

Map<String, dynamic> _salesCandidatesJson() => {
  'items': [
    {
      'orderId': 'sales-order-1',
      'billNo': 'SO-20260811-001',
      'billDate': '2026-08-11',
      'clientName': '测试客户',
      'lines': [
        {
          'salesOrderItemId': 'sales-line-a',
          'lineNo': 1,
          'goodsId': 'goods-a',
          'goodsCode': 'A-001',
          'goodsName': '候选产品 A',
          'unitId': 'unit-1',
          'unitName': '个',
          'orderedQty': 10,
          'alreadyPlannedQty': 2,
          'remainingQty': 8,
          'deliveryDate': '2026-08-20',
        },
        {
          'salesOrderItemId': 'sales-line-b',
          'lineNo': 2,
          'goodsId': 'goods-b',
          'goodsCode': 'B-001',
          'goodsName': '候选产品 B',
          'unitId': 'unit-1',
          'unitName': '个',
          'orderedQty': 6,
          'alreadyPlannedQty': 1,
          'remainingQty': 5,
          'deliveryDate': '2026-08-22',
        },
      ],
    },
  ],
  'page': 1,
  'size': 100,
  'total': 1,
  'totalPages': 1,
};

Map<String, dynamic> _pagedSalesCandidatesJson(int page) {
  final firstPage = page <= 1;
  final suffix = firstPage ? 'a' : 'b';
  final label = firstPage ? 'A' : 'B';
  return {
    'items': [
      {
        'orderId': 'mobile-sales-order-$suffix',
        'billNo': 'SO-MOBILE-$label',
        'billDate': '2026-08-11',
        'clientName': '手机测试客户',
        'lines': [
          {
            'salesOrderItemId': 'mobile-sales-line-$suffix',
            'lineNo': 1,
            'goodsId': 'mobile-goods-$suffix',
            'goodsCode': 'MOBILE-$label',
            'goodsName': '手机候选产品 $label',
            'unitId': 'unit-1',
            'unitName': '个',
            'orderedQty': 10,
            'alreadyPlannedQty': firstPage ? 2 : 3,
            'remainingQty': firstPage ? 8 : 7,
            'deliveryDate': firstPage ? '2026-08-20' : '2026-08-22',
          },
        ],
      },
    ],
    'page': firstPage ? 1 : 2,
    'size': 100,
    'total': 2,
    'totalPages': 2,
  };
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

Map<String, dynamic> _buySafetySplitAnalysisJson() {
  final json = _buySelectionAnalysisJson();
  final buyMaterials = (json['flatMaterials'] as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .where((material) => material['sourceConfirmed'] == 'BUY');
  for (final material in buyMaterials) {
    material
      ..['goodsId'] = 'shared-buy-goods'
      ..['colorId'] = 'shared-color'
      ..['unitId'] = 'unit-1'
      ..['materialKey'] = 'shared-buy-goods|shared-color|unit-1'
      ..['demandSupplyGapQty'] = 8
      ..['safetyStockQty'] = 10
      ..['warehouseBreakdown'] = [
        {
          'warehouseId': 'warehouse-1',
          'warehouseCode': 'WH-01',
          'warehouseName': '主仓',
          'onHandQty': 2,
          'reservedQty': 0,
          'availableQty': 0,
          'ownPeggedQty': 0,
          'publicAvailableQty': 2,
          'openSafetySupplyQty': 2,
          'safetyReplenishmentGapQty': 6,
        },
      ];
  }
  return json;
}

Map<String, dynamic> _buySelectionNotifiedAnalysisJson() {
  final json = _buySelectionAnalysisJson();
  final materials = (json['flatMaterials'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final notified = materials.firstWhere(
    (material) => material['materialLineId'] == 'buy-line-2',
  );
  notified['notifiedTargets'] = [
    {
      'target': 'BUY',
      'documentType': 'PURCHASE_REQUEST',
      'documentId': 'purchase-request-1',
      'status': 'CREATED',
    },
  ];
  return json;
}

Map<String, dynamic> _bulkRouteAnalysisJson({
  required int count,
  required List<String> allowedActions,
  int version = 3,
  String fingerprintChar = 'a',
  int confirmedCount = 0,
  int notifiedCount = 0,
}) {
  final json = _analysisJson(allowedActions)
    ..['version'] = version
    ..['fingerprint'] = fingerprintChar * 64;
  json['flatMaterials'] = [
    for (var index = 1; index <= count; index++)
      {
        'materialLineId': 'bulk-line-$index',
        'analysisLineId': 'product-line-1',
        'nodeKey': 'bulk-node-$index',
        'actionGroupKey': 'bulk-action-${index.toString().padLeft(3, '0')}',
        'materialKey': 'bulk-goods-$index||unit-1',
        'goodsId': 'bulk-goods-$index',
        'goodsCode': 'BULK-$index',
        'goodsName': '批量缺料 $index',
        'unitName': '个',
        'level': 1,
        'path': ['测试产品', '批量缺料 $index'],
        'requiredQty': 10,
        'allocatedAvailableQty': 2,
        'availableQty': 2,
        'shortageQty': 8,
        'sourceSuggestion': 'BUY',
        'sourceConfirmed': index <= confirmedCount ? 'BUY' : null,
        'routeConfirmed': index <= confirmedCount,
        'controlStage': 'START',
        'hardGate': true,
        'actionable': true,
        if (index <= notifiedCount)
          'notifiedTargets': [
            {
              'target': 'BUY',
              'documentType': 'PURCHASE_REQUEST',
              'documentId': 'bulk-purchase-request-$index',
              'status': 'CREATED',
            },
          ],
      },
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
      goodsName: '自制组件 A(另一 BOM 路径)',
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
    'goodsName': '自制组件 A(备料任务)',
    'unitName': '个',
    'requestedQty': 8,
    'submittedQty': 0,
    'approvedQty': 0,
    'remainingQty': 8,
    'readyNowQty': 8,
    'readinessRatio': 1,
    'allocationPriority': 3,
  });
  return json;
}

Map<String, dynamic> _pendingMakeCandidateAnalysisJson({
  bool lowerLevelPending = true,
  bool includeRealChild = false,
  bool actionable = true,
  bool includeMixedReadyCandidate = false,
}) {
  final json = _analysisJson(const ['NOTIFY_SUPPLY', 'GENERATE_PLAN']);
  final childShortage = lowerLevelPending ? 4 : 0;
  final parent = {
    ..._routeMaterial(
      id: 'pending-make-1',
      nodeKey: 'pending-make-node-1',
      actionGroupKey: 'pending-make-action-1',
      goodsCode: 'MAKE-PENDING',
      goodsName: '待自制壳体',
      route: 'MAKE',
      controlStage: 'ASSEMBLY',
    ),
    'lowerLevelPending': lowerLevelPending,
    'actionable': actionable,
    if (includeRealChild)
      'notifiedTargets': [
        {
          'target': 'MAKE',
          'documentType': 'PREPLAN_MAKE_TASK',
          'documentId': 'pending-make-child-1',
          'status': 'CREATED',
        },
      ],
  };
  Map<String, dynamic> child({
    required String id,
    required String materialKey,
    required String goodsCode,
    required String goodsName,
  }) => {
    ..._routeMaterial(
      id: id,
      nodeKey: 'node-$id',
      actionGroupKey: 'action-$id',
      goodsCode: goodsCode,
      goodsName: goodsName,
      route: 'BUY',
      controlStage: 'ASSEMBLY',
    ),
    'parentNodeKey': 'pending-make-node-1',
    'materialKey': materialKey,
    'level': 2,
    'path': ['测试产品', '待自制壳体', goodsName],
    'allocatedAvailableQty': lowerLevelPending ? 0 : 10,
    'availableQty': lowerLevelPending ? 0 : 10,
    'shortageQty': childShortage,
    'sourceConfirmed': null,
    'routeConfirmed': false,
    'actionable': lowerLevelPending,
  };
  json['flatMaterials'] = [
    parent,
    child(
      id: 'pending-child-a-1',
      materialKey: 'pending-child-a||unit-1',
      goodsCode: 'CHILD-A',
      goodsName: '下层物料 A',
    ),
    child(
      id: 'pending-child-a-2',
      materialKey: 'pending-child-a||unit-1',
      goodsCode: 'CHILD-A',
      goodsName: '下层物料 A(另一 BOM 路径)',
    ),
    child(
      id: 'pending-child-b-1',
      materialKey: 'pending-child-b||unit-1',
      goodsCode: 'CHILD-B',
      goodsName: '下层物料 B',
    ),
  ];
  if (includeMixedReadyCandidate) {
    (json['flatMaterials']! as List<Map<String, dynamic>>).addAll([
      <String, dynamic>{
        ..._routeMaterial(
          id: 'pending-make-ready-1',
          nodeKey: 'pending-make-ready-node-1',
          actionGroupKey: 'pending-make-ready-action-1',
          goodsCode: 'MAKE-READY',
          goodsName: '已齐套自制件',
          route: 'MAKE',
          controlStage: 'ASSEMBLY',
        ),
        'lowerLevelPending': false,
        'actionable': true,
      },
      <String, dynamic>{
        ..._routeMaterial(
          id: 'pending-ready-child-1',
          nodeKey: 'pending-ready-child-node-1',
          actionGroupKey: 'pending-ready-child-action-1',
          goodsCode: 'READY-CHILD',
          goodsName: '已齐套下层物料',
          route: 'BUY',
          controlStage: 'ASSEMBLY',
        ),
        'parentNodeKey': 'pending-make-ready-node-1',
        'materialKey': 'pending-ready-child||unit-1',
        'level': 2,
        'path': ['测试产品', '已齐套自制件', '已齐套下层物料'],
        'allocatedAvailableQty': 10,
        'availableQty': 10,
        'shortageQty': 0,
        'sourceConfirmed': null,
        'routeConfirmed': false,
        'actionable': false,
      },
    ]);
  }
  if (includeRealChild) {
    (json['products']! as List<dynamic>).add({
      'analysisLineId': 'pending-make-child-1',
      'sourceType': 'MAKE_COMPONENT',
      'parentAnalysisLineId': 'product-line-1',
      'parentGoodsName': '测试产品',
      'goodsId': 'goods-pending-make-1',
      'goodsCode': 'MAKE-PENDING',
      'goodsName': '待自制壳体(自制备料)',
      'requestedQty': 8,
      'remainingQty': 8,
      'readyNowQty': 0,
      'readinessRatio': 0,
      'allocationPriority': 3,
    });
  }
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
      'goodsName': '自制短缺件(自制备料)',
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

Map<String, dynamic> _makeExecutionProjectionJson({
  bool inventoryCovered = false,
}) {
  final json = _makeStatusAnalysisJson(
    childSubmitted: 10,
    childApproved: 10,
    shortage: inventoryCovered ? 0 : 10,
    planExecutionStatus: 'IN_PROGRESS',
    latestPlanId: 'plan-make-execution',
    latestPlanNo: 'SJ20260831000001',
  );
  final material =
      (json['flatMaterials'] as List<dynamic>).single as Map<String, dynamic>;
  material
    ..['requiredQty'] = 10
    ..['allocatedAvailableQty'] = inventoryCovered ? 10 : 0
    ..['exactPeggedQty'] = 0
    ..['availableQty'] = inventoryCovered ? 10 : 0
    ..['shortageQty'] = inventoryCovered ? 0 : 10
    ..['demandSupplyGapQty'] = inventoryCovered ? 0 : 10
    ..['requirementState'] = 'ACTIVE'
    ..['warehouseBreakdown'] = [
      {
        'warehouseId': 'warehouse-1',
        'publicAvailableQty': inventoryCovered ? 10 : 0,
        'openSafetySupplyQty': 0,
        'safetyReplenishmentGapQty': 0,
      },
    ];
  final child =
      (json['products'] as List<dynamic>).last as Map<String, dynamic>;
  child
    ..['requestedQty'] = 10
    ..['submittedQty'] = 10
    ..['approvedQty'] = 10
    ..['remainingQty'] = 0
    ..['readyNowQty'] = 0
    ..['planExecutionPlannedQty'] = 10
    ..['planExecutionInboundQty'] = 0
    ..['planExecutionProgressRatio'] = 0;
  return json;
}

Map<String, dynamic> _completedMakeAnalysisJson() {
  final json = _makeStatusAnalysisJson(
    childSubmitted: 8,
    childApproved: 8,
    shortage: 0,
    planExecutionStatus: 'COMPLETED',
    latestPlanId: 'plan-make-done',
    latestPlanNo: 'SJ-MAKE-DONE-001',
  );
  final child =
      (json['products'] as List<dynamic>).last as Map<String, dynamic>;
  child
    ..['planExecutionPlannedQty'] = 8
    ..['planExecutionInboundQty'] = 8
    ..['planExecutionProgressRatio'] = 1.0;
  return json;
}

Map<String, dynamic> _makeChildBomRootAnalysisJson() {
  final json = _requirementStateAnalysisJson();
  final child =
      (json['products'] as List<dynamic>).last as Map<String, dynamic>;
  child
    ..['parentGoodsName'] = '测试产品'
    ..['hasProductionMaterialChildren'] = true;
  (json['flatMaterials'] as List<dynamic>).add({
    ..._routeMaterial(
      id: 'make-child-own-material',
      nodeKey: 'node-make-child-own-material',
      actionGroupKey: 'action-make-child-own-material',
      goodsCode: 'MAKE-CHILD-MAT',
      goodsName: '自制子任务原料',
      route: 'BUY',
      controlStage: 'START',
    ),
    'analysisLineId': 'make-child-owner-12345678',
    'materialKey': 'goods-make-child-own-material||unit-1',
    'path': ['需求状态 delegated(自制备料)', '自制子任务原料'],
    'requiredQty': 4,
    'allocatedAvailableQty': 0,
    'availableQty': 0,
    'shortageQty': 4,
    'demandSupplyGapQty': 4,
    'requirementState': 'ACTIVE',
    'actionable': false,
  });
  return json;
}

Map<String, dynamic> _requirementStateAnalysisJson() {
  final json = _analysisJson(const ['VIEW']);
  json['flatMaterials'] = [
    _requirementStateMaterial(
      id: 'active-zero',
      state: 'ACTIVE',
      requiredQty: 10,
      demandSupplyGapQty: 10,
      shortageQty: 10,
      actionable: true,
    ),
    _requirementStateMaterial(
      id: 'delegated',
      state: 'DELEGATED_TO_MAKE_CHILD',
      delegated: true,
    ),
    _requirementStateMaterial(
      id: 'parent-covered',
      state: 'INACTIVE_PARENT_COVERED',
    ),
    _requirementStateMaterial(
      id: 'parent-route',
      state: 'INACTIVE_PARENT_ROUTE',
    ),
    _requirementStateMaterial(
      id: 'reference',
      state: 'INACTIVE_REFERENCE',
      controlStage: 'REFERENCE',
    ),
    _requirementStateMaterial(id: 'transferred', state: 'TRANSFERRED_TO_PLAN'),
    _requirementStateMaterial(id: 'inactive', state: 'INACTIVE'),
  ];
  (json['products'] as List<dynamic>).add({
    'analysisLineId': 'make-child-owner-12345678',
    'sourceType': 'MAKE_COMPONENT',
    'parentAnalysisLineId': 'product-line-1',
    'parentGoodsName': '需求状态 delegated',
    'goodsId': 'goods-delegated',
    'goodsCode': 'REQ-delegated',
    'goodsName': '需求状态 delegated(自制备料)',
    'requestedQty': 12,
    'submittedQty': 12,
    'approvedQty': 12,
    'remainingQty': 0,
    'readyNowQty': 0,
    'planExecutionStatus': 'IN_PROGRESS',
    'planExecutionPlannedQty': 12,
    'planExecutionInboundQty': 0,
    'planExecutionProgressRatio': 0,
  });
  return json;
}

Map<String, dynamic> _requirementStateMaterial({
  required String id,
  required String state,
  double requiredQty = 0,
  double demandSupplyGapQty = 0,
  double shortageQty = 0,
  bool actionable = false,
  bool delegated = false,
  String controlStage = 'ASSEMBLY',
}) => {
  ..._routeMaterial(
    id: id,
    nodeKey: 'node-$id',
    actionGroupKey: 'action-$id',
    goodsCode: 'REQ-$id',
    goodsName: '需求状态 $id',
    route: 'BUY',
    controlStage: controlStage,
  ),
  'requiredQty': requiredQty,
  'allocatedAvailableQty': 0,
  'exactPeggedQty': 0,
  'availableQty': 0,
  'shortageQty': shortageQty,
  'demandSupplyGapQty': demandSupplyGapQty,
  'requirementState': state,
  'actionable': actionable,
  if (delegated) 'delegatedToAnalysisLineId': 'make-child-owner-12345678',
  if (delegated) 'delegatedToSourceRef': '自制备料 2026-08-30 abcd',
  if (delegated) 'delegatedToRequestedQty': 12,
  if (delegated)
    'notifiedTargets': [
      {
        'target': 'MAKE',
        'documentType': 'PREPLAN_MAKE_TASK',
        'documentId': 'make-child-owner-12345678',
        'status': 'CREATED',
      },
    ],
  'warehouseBreakdown': [
    {
      'warehouseId': 'warehouse-1',
      'publicAvailableQty': 0,
      'openSafetySupplyQty': 0,
      'safetyReplenishmentGapQty': 0,
    },
  ],
};

Map<String, dynamic> _sameGoodsMakePathAnalysisJson() {
  final json = _analysisJson(const ['VIEW']);
  Map<String, dynamic> makePath({
    required String id,
    required String nodeKey,
    String? childId,
  }) => {
    ..._routeMaterial(
      id: id,
      nodeKey: nodeKey,
      actionGroupKey: 'action-$id',
      goodsCode: 'SAME-MAKE',
      goodsName: '同货自制件',
      route: 'MAKE',
      controlStage: 'ASSEMBLY',
    ),
    'goodsId': 'goods-same-make',
    'requiredQty': 10,
    'allocatedAvailableQty': 0,
    'availableQty': 0,
    'shortageQty': 10,
    'demandSupplyGapQty': 10,
    'requirementState': 'ACTIVE',
    'notifiedTargets': [
      {
        'target': 'MAKE',
        'documentType': 'PREPLAN_MAKE_TASK',
        'documentId': ?childId,
        'status': 'CREATED',
      },
    ],
  };
  json['flatMaterials'] = [
    makePath(
      id: 'make-exact',
      nodeKey: 'node-make-exact',
      childId: 'same-make-child-exact',
    ),
    makePath(id: 'make-missing-id', nodeKey: 'node-make-missing-id'),
  ];
  (json['products'] as List<dynamic>).add({
    'analysisLineId': 'same-make-child-exact',
    'sourceType': 'MAKE_COMPONENT',
    'parentAnalysisLineId': 'product-line-1',
    'parentGoodsName': '测试产品',
    'goodsId': 'goods-same-make',
    'goodsCode': 'SAME-MAKE',
    'goodsName': '同货自制件(精确 child)',
    'requestedQty': 10,
    'submittedQty': 10,
    'approvedQty': 10,
    'remainingQty': 0,
    'readyNowQty': 0,
    'planExecutionStatus': 'IN_PROGRESS',
    'latestPlanId': 'plan-same-make-exact',
    'planExecutionPlannedQty': 10,
    'planExecutionInboundQty': 2,
    'planExecutionProgressRatio': 0.2,
  });
  return json;
}

/// 两个产品共用同一种物料「共享电机」（两条独立 BOM 路径），外加一条未确认
/// 路线的独立件，用于验证按物料汇总视图的跨产品聚合、pegging 明细展开和
/// 逐路径勾选下达。
Map<String, dynamic> _aggregateAnalysisJson() {
  final json = _analysisJson(const ['NOTIFY_SUPPLY', 'REALLOCATE']);
  json['flatMaterials'] = [
    {
      'materialLineId': 'agg-path-1',
      'analysisLineId': 'product-line-1',
      'nodeKey': 'agg-node-1',
      'actionGroupKey': 'agg-action-1',
      'materialKey': 'goods-shared-motor||unit-1',
      'goodsId': 'goods-shared-motor',
      'goodsCode': 'MTR-1',
      'goodsName': '共享电机',
      'unitName': '个',
      'level': 1,
      'path': ['测试产品', '共享电机'],
      'requiredQty': 10,
      'allocatedAvailableQty': 4,
      'availableQty': 4,
      'shortageQty': 6,
      'sourceSuggestion': 'BUY',
      'sourceConfirmed': 'BUY',
      'routeConfirmed': true,
      'controlStage': 'START',
      'hardGate': true,
      'actionable': true,
    },
    {
      'materialLineId': 'agg-path-2',
      'analysisLineId': 'product-line-2',
      'nodeKey': 'agg-node-2',
      'actionGroupKey': 'agg-action-2',
      'materialKey': 'goods-shared-motor||unit-1',
      'goodsId': 'goods-shared-motor',
      'goodsCode': 'MTR-1',
      'goodsName': '共享电机',
      'unitName': '个',
      'level': 1,
      'path': ['第二测试产品', '共享电机'],
      'requiredQty': 5,
      'allocatedAvailableQty': 0,
      'availableQty': 4,
      'shortageQty': 5,
      'sourceSuggestion': 'BUY',
      'sourceConfirmed': 'BUY',
      'routeConfirmed': true,
      'controlStage': 'START',
      'hardGate': true,
      'actionable': true,
    },
    {
      'materialLineId': 'agg-path-3',
      'analysisLineId': 'product-line-1',
      'nodeKey': 'agg-node-3',
      'actionGroupKey': 'agg-action-3',
      'materialKey': 'goods-solo||unit-1',
      'goodsId': 'goods-solo',
      'goodsCode': 'SOLO-1',
      'goodsName': '独立件',
      'unitName': '个',
      'level': 1,
      'path': ['测试产品', '独立件'],

      'requiredQty': 8,
      'allocatedAvailableQty': 5,
      'availableQty': 5,
      'shortageQty': 3,
      'sourceSuggestion': 'BUY',
      'routeConfirmed': false,
      'controlStage': 'FINISH',
      'hardGate': true,
      'actionable': true,
    },
  ];
  return json;
}

/// 借用 4 件生效后的分析视图：agg-path-1（测试产品）被调走 4 件，
/// agg-path-2（第二测试产品）调入 4 件；双向明细可撤销。
Map<String, dynamic> _borrowedAnalysisJson() {
  final json = _aggregateAnalysisJson();
  final materials = (json['flatMaterials'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final from = materials.singleWhere(
    (material) => material['materialLineId'] == 'agg-path-1',
  );
  from['allocatedAvailableQty'] = 0;
  from['shortageQty'] = 10;
  from['borrowedOutQty'] = 4;
  from['borrowRefs'] = [
    {
      'borrowId': 'borrow-1',
      'direction': 'OUT',
      'qty': 4,
      'requestedQty': 4,
      'counterpartProduct': '第二测试产品',
      'reason': '客户加急，先保这单',
    },
  ];
  final to = materials.singleWhere(
    (material) => material['materialLineId'] == 'agg-path-2',
  );
  to['allocatedAvailableQty'] = 4;
  to['shortageQty'] = 1;
  to['borrowedInQty'] = 4;
  to['borrowRefs'] = [
    {
      'borrowId': 'borrow-1',
      'direction': 'IN',
      'qty': 4,
      'requestedQty': 4,
      'counterpartProduct': '测试产品',
      'reason': '客户加急，先保这单',
    },
  ];
  return json;
}

Map<String, dynamic> _crossReallocatedAnalysisJson({
  bool inbound = false,
  String status = 'PARTIAL',
  double currentEffectiveQty = 4,
}) {
  final json = _aggregateAnalysisJson();
  final materials = (json['flatMaterials'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final material = materials.singleWhere(
    (row) => row['materialLineId'] == 'agg-path-1',
  );
  material[inbound ? 'crossReallocatedInQty' : 'crossReallocatedOutQty'] =
      currentEffectiveQty;
  material['priorityPendingQty'] =
      inbound || !const {'OPEN', 'PARTIAL'}.contains(status) ? 0 : 2;
  material['priorityFulfilledQty'] = inbound ? 0 : 2;
  material['crossReallocationRefs'] = [
    {
      'id': 'cross-1',
      'direction': inbound ? 'IN' : 'OUT',
      'status': status,
      'counterpartAnalysisId': inbound ? 'source-analysis' : 'target-analysis',
      'counterpartVersion': 4,
      'counterpartFingerprint': 'e' * 64,
      'counterpartLabel': inbound ? '订单 XS-001' : '订单 XS-002',
      'counterpartProduct': inbound ? '来源产品' : '加急产品',
      'qty': 4,
      'currentEffectiveQty': currentEffectiveQty,
      'priorityFulfilledQty': inbound ? 0 : 2,
      'priorityOpenQty': inbound ? 0 : 2,
      'reason': '客户订单加急',
      'canRevoke': false,
      'revokeBlockedReason': const {'REVERSED', 'CANCELLED'}.contains(status)
          ? '让料记录已经关闭'
          : '接受计划已领料',
      'replenishmentRefs': inbound
          ? <Map<String, dynamic>>[]
          : [
              {
                'route': 'BUY',
                'documentNo': 'PO-001',
                'receiptNo': 'WR-001',
                'qty': 2,
              },
            ],
    },
  ];
  return json;
}

Map<String, dynamic> _crossReallocatableAnalysisJson(
  List<String> allowedActions,
) {
  final json = _crossReallocatedAnalysisJson();
  json['allowedActions'] = allowedActions;
  final materials = (json['flatMaterials'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final material = materials.singleWhere(
    (row) => row['materialLineId'] == 'agg-path-1',
  );
  final refs = material['crossReallocationRefs'] as List<dynamic>;
  (refs.single as Map<String, Object>)['canRevoke'] = true;
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

Map<String, dynamic> _confirmedWorkCardJson({
  String planId = 'plan-1',
  String planBillNo = 'PP-20260809-001',
  String packageId = 'package-1',
  String segmentId = 'segment-1',
  String segmentCode = 'SEG-001',
}) => {
  'planId': planId,
  'planBillNo': planBillNo,
  'planBillDate': '2026-08-09',
  'deliveryDate': '2026-08-12',
  'packageId': packageId,
  'packageStatus': 'CONFIRMED',
  'executionModelVersion': 1,
  'packageLockVersion': 1,
  'confirmedAt': '2026-08-09T08:30:00Z',
  'approverName': '审核员',
  'warehouseId': 'warehouse-1',
  'warehouseCode': 'WH-01',
  'warehouseName': '主仓',
  'generatedAt': '2026-08-09T08:31:00Z',
  'namePolicy': 'CURRENT_MASTER_DATA',
  'cards': [
    {
      'segmentId': segmentId,
      'segmentCode': segmentCode,
      'sourcePlanItemId': 'plan-item-1',
      'sourceLineNo': 1,
      'productNo': 'V6-0001',
      'productGoodsId': 'goods-1',
      'productCode': 'P-001',
      'productName': '测试产品',
      'productSpec': '三插压板',
      'productUnitName': '件',
      'plannedQty': 4,
      'status': 'READY',
      'materialRequirementMode': 'ZERO_MATERIAL',
      'zeroMaterialReason': 'DIRECT_MAKE',
      'workshopName': '装配一车间',
      'responsibleEmployeeName': '负责人',
      'planBeginDate': '2026-08-09',
      'planEndDate': '2026-08-12',
      'materials': <Map<String, dynamic>>[],
    },
  ],
};

class _Harness {
  const _Harness(this.requests);

  final List<RequestOptions> requests;
}

/// 点「提交采购/委外/自制」按钮后会先弹数量确认对话框（默认 = 缺口−在途）；
/// 测试默认全量提交，直接点确认。
Future<void> _confirmSupplyQuantityDialog(WidgetTester tester) async {
  final confirm = find.byKey(const Key('supply-quantity-confirm'));
  await tester.ensureVisible(confirm);
  await tester.pumpAndSettle();
  await tester.tap(confirm);
  await tester.pumpAndSettle();
}
