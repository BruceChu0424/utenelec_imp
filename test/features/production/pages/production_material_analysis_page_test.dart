import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/models/workforce_overview.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/production_department_provider.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/list_refresh_provider.dart';
import 'package:uten_imp/features/production/providers/production_execution_refresh.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  testWidgets(
    'new MAKE child is visible in the first bounded workshop window',
    (tester) async {
      final initial = _makeTreeAnalysisJson();
      final notified = _makeReadyChildAnalysisJson();
      for (final view in [initial, notified]) {
        view['allowedActions'] = [
          'NOTIFY_SUPPLY',
          'GENERATE_PLAN',
          'PLAN_PREVIEW',
        ];
        view['products'] = [
          ...(view['products'] as List<dynamic>),
          for (var index = 0; index < 150; index++)
            {
              'analysisLineId': 'extra-$index',
              'sourceType': 'STOCK',
              'goodsId': 'extra-goods-$index',
              'goodsName': '其它产品 $index',
              'requestedQty': 1,
              'remainingQty': 1,
              'readyNowQty': 1,
              'canSchedule': true,
              'maxSchedulableQty': 1,
            },
        ];
      }
      // 2026-09-05 简化：行菜单「创建自制子件任务」退役——直接以「已有子件行」
      // 的快照进入（等价于创建后的状态），锁定同样的首屏窗口断言。
      final harness = await _pumpPage(
        tester,
        size: const Size(1600, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisNotify,
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: notified,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductionMaterialAnalysisPage)),
      );
      await _openBucketDetail(tester, 'workshop');
      expect(find.text('自制组件 A(备料任务)'), findsOneWidget);
      // 直接进入（无刚创建动作）→ 不预选也不置顶；旧「创建后自动选中置顶」
      // 随行菜单退役，窗口断言只锁首屏有界装载。
      expect(_bucketRowCheckboxValue(tester, '自制组件 A(备料任务)'), isFalse);
      expect(
        tester.widgetList<TextField>(find.byType(TextField)).length,
        lessThanOrEqualTo(105),
      );
      expect(
        container.read(listRefreshTickProvider(productionExecutionRefreshKey)),
        0,
      );
      expect(
        harness.requests.where(
          (request) => request.path.endsWith('/issue-plans'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets(
    'creating a production plan from a candidate issues child task and plan together',
    (tester) async {
      // 2026-09-05 ADR-71：车间桶单按钮「创建生产计划」——候选行与本批数量/
      // 车间/负责人一次原子提交（服务端一个事务建子件任务+出计划）。
      final initial = _makeTreeAnalysisJson()
        ..['allowedActions'] = [
          'NOTIFY_SUPPLY',
          'GENERATE_PLAN',
          'PLAN_PREVIEW',
        ];
      final notified = _makeReadyChildAnalysisJson()
        ..['allowedActions'] = [
          'NOTIFY_SUPPLY',
          'GENERATE_PLAN',
          'PLAN_PREVIEW',
        ];
      final notifiedChild =
          (notified['products']! as List<dynamic>).last as Map<String, dynamic>;
      notifiedChild
        ..['canSchedule'] = true
        ..['maxSchedulableQty'] = 8;
      final harness = await _pumpPage(
        tester,
        size: const Size(1600, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisNotify,
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: initial,
        responseOverride: (request) {
          if (request.path.endsWith('/issue-plans')) {
            return {
              'analysis': notified,
              'plans': [
                {
                  'planId': 'plan-1',
                  'planNo': 'PP-20260905-001',
                  'status': 'DRAFT',
                  'segmentIds': <String>[],
                  'drawIds': <String>[],
                },
              ],
            };
          }
          return null;
        },
      );
      await _openBucketDetail(tester, 'workshop');
      // 候选行同一张表单：默认数量=全部剩余 8，车间空待填（负责人随车间带出）。
      final candidateRow = find
          .ancestor(of: find.text('自制组件 A'), matching: find.byType(Row))
          .first;
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: candidateRow,
                matching: find.byType(TextField),
              ),
            )
            .controller
            ?.text,
        '8',
      );
      await _pickBucketRowWorkshop(tester, candidateRow, '装配一车间');
      await _tapBucketRowCheckbox(tester, '自制组件 A');
      await tester.tap(
        find.byKey(const Key('material-analysis-bucket-action-ready')),
      );
      await tester.pumpAndSettle();

      // 候选行直发：客户端只发一次 issue-plans（建子件任务在服务端同一事务里）。
      final issue = harness.requests.singleWhere(
        (request) => request.path.endsWith('/issue-plans'),
      );
      expect(
        harness.requests.where((request) => request.path.endsWith('/notify')),
        isEmpty,
      );
      expect((issue.data! as Map<String, dynamic>)['lines'], [
        {
          'materialLineId': 'make-path-1',
          'qty': 8.0,
          'departmentId': 'workshop-1',
          'workshopName': '装配一车间',
          'workerId': 'worker-1',
        },
      ]);
      expect(tester.takeException(), isNull);
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
    // 说明收进标签旁 ⓘ 悬停提示（fieldLabel 约定）。
    expect(find.byTooltip('同一需求请始终使用同一个编号'), findsOneWidget);
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
      // 2026-09-04 改版口径：主页面不再渲染产品大卡片，两个用户来源产品
      // 都应出现在「可安排生产」分桶详情页的表格行里。
      await _openBucketDetail(tester, 'workshop');
      expect(find.text('测试产品(P-1)'), findsOneWidget);
      expect(find.text('第二测试产品(P-2)'), findsOneWidget);
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
          Perm.productionMaterialAnalysisGenerate,
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
          final json = _analysisJson(const [
            'REFRESH',
            'GENERATE_PLAN',
            'PLAN_PREVIEW',
          ]);
          final firstProduct =
              (json['products']! as List<dynamic>).first
                  as Map<String, dynamic>;
          firstProduct['readyNowQty'] = detailReads == 1 ? 0 : 7;
          firstProduct['canSchedule'] = detailReads != 1;
          firstProduct['maxSchedulableQty'] = detailReads == 1 ? 0 : 7;
          firstProduct['readinessRatio'] = detailReads == 1 ? 0 : 0.7;
          json['version'] = detailReads == 1 ? 3 : 4;
          json['fingerprint'] = (detailReads == 1 ? 'a' : 'b') * 64;
          return json;
        },
      );

      expect(detailReads, 2);
      // ADR-71：本批数量默认=剩余需求 10（齐套上限不再预填，齐套拆批由
      // 执行段 WAITING/READY 完成）。
      await _openBucketDetail(tester, 'workshop');
      expect(find.text('测试产品'), findsOneWidget);
      final refreshedRow = find
          .ancestor(of: find.text('测试产品').first, matching: find.byType(Row))
          .first;
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: refreshedRow,
                matching: find.byType(TextField),
              ),
            )
            .controller
            ?.text,
        '10',
      );
      await _closeBucketDetail(tester);
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

      await _createDefaultRoutes(tester);
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
          firstProduct['canSchedule'] = detailReads != 1;
          firstProduct['maxSchedulableQty'] = detailReads == 1 ? 0 : 7;
          firstProduct['readinessRatio'] = detailReads == 1 ? 0 : 0.7;
          json['version'] = detailReads;
          json['fingerprint'] = (detailReads == 1 ? 'a' : 'b') * 64;
          return json;
        },
      );

      expect(detailReads, 1);
      // 2026-09-04 改版口径：产品阻断徽标/门禁图标/勾选框随卡片下线，改为在
      // 「暂不可安排」桶断言产品被阻断，轮询后在「可安排生产」桶断言解除。
      await _openBucketDetail(tester, 'workshop', stateFilter: '需处理');
      // 产品列展示「名称（编码）」。
      expect(find.text('测试产品(P-1)'), findsOneWidget);
      await _closeBucketDetail(tester);

      await tester.pump(const Duration(seconds: 45));
      await tester.pumpAndSettle();

      expect(detailReads, 2);
      await _openBucketDetail(tester, 'workshop');
      expect(find.text('测试产品(P-1)'), findsOneWidget);
      expect(find.text('第二测试产品(P-2)'), findsOneWidget);
      await _closeBucketDetail(tester);

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
      final analysis = _analysisJson(const [
        'VIEW',
        'GENERATE_PLAN',
        'PLAN_PREVIEW',
      ]);
      final product =
          (analysis['products']! as List<dynamic>).first
              as Map<String, dynamic>;
      product
        ..['requestedQty'] = 10
        ..['submittedQty'] = 10
        ..['approvedQty'] = 0
        ..['remainingQty'] = 0
        ..['readyNowQty'] = 0
        ..['canSchedule'] = false
        ..['maxSchedulableQty'] = 0
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
        withPlanRoute: true,
      );

      // 2026-09-04 改版口径：执行状态面板/进度条随产品卡片下线——执行阶段
      // 在「已转生产」桶详情行断言；50% 进度体现在行文本上（未回传时为
      // 「执行进度待回传」，绝不发明 0%）。

      await _openBucketDetail(tester, 'workshop', stateFilter: '已下达');
      expect(find.text('生产中 · 可报工 50%'), findsOneWidget);
      // 已转生产行双击进入生产计划跟踪（旧卡片的整高计划入口动作迁移；
      // MasterDataTableView 列表页交互 = 单击选中、双击打开）。
      final transferredRow = find.textContaining('测试产品');
      expect(transferredRow, findsOneWidget);
      await tester.tap(transferredRow);
      await tester.tap(transferredRow);
      await tester.pumpAndSettle();
      expect(find.text('已打开计划 plan-running-1'), findsOneWidget);
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

    // 2026-09-06 词表：无进度数据时显示「生产中 · 可报工」（不带百分比），
    // 绝不发明「生产中 · 可报工 0%」。
    await _openBucketDetail(tester, 'workshop', stateFilter: '已下达');
    expect(find.text('生产中 · 可报工'), findsOneWidget);
    expect(find.textContaining('生产中 · 可报工 0%'), findsNothing);
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
            ..['canSchedule'] = false
            ..['maxSchedulableQty'] = 0
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

      // 2026-09-04 改版口径：执行进度面板迁移到「已转生产」桶详情行；桶页
      // 打开期间宿主页轮询/恢复刷新暂停，因此每次返回前先关掉详情页。
      // 版本与指纹不变（CAS 头不变），仅动态执行投影变化也必须重建页面。
      Future<String> readTransferredStage() async {
        await _openBucketDetail(tester, 'workshop', stateFilter: '已下达');
        final stageCell = find.textContaining('生产中 · 可报工 ');
        final text = tester.widget<Text>(stageCell).data!;
        await _closeBucketDetail(tester);
        return text;
      }

      expect(await readTransferredStage(), '生产中 · 可报工 10%');

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
      expect(await readTransferredStage(), '生产中 · 可报工 30%');

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
      expect(await readTransferredStage(), '生产中 · 可报工 100%');
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

      await _createDefaultRoutes(tester);
      expect(
        find.byKey(
          const Key('material-analysis-create-routes'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 45));
      await tester.pumpAndSettle();
      expect(detailReads, 1);
      expect(
        find.byKey(
          const Key('material-analysis-create-routes'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );

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
      final analysis = _analysisJson(const [
        'VIEW',
        'GENERATE_PLAN',
        'PLAN_PREVIEW',
      ]);
      final products = (analysis['products']! as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final product = products.first;
      final materialBackedProduct = products.last;
      product
        ..['readyNowQty'] = 10
        ..['canSchedule'] = true
        ..['maxSchedulableQty'] = 10
        ..['readyByDateQty'] = 10
        ..['readinessRatio'] = 1
        ..['hasProductionMaterialChildren'] = false;
      materialBackedProduct
        ..['readyNowQty'] = 6
        ..['canSchedule'] = true
        ..['maxSchedulableQty'] = 6
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
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: analysis,
        theme: ThemeData.dark(),
        textScale: 1.3,
      );

      // 2026-09-04 改版口径：产品大卡片（可直接自制/齐套进度条/卡内状态栏）
      // 下线——「无子层产品不是 BOM 资料错误、可直接排产」现在体现在：两个
      // 产品都在「可安排生产」桶里，行内默认本批数量 = 最多可生产，且因为
      // 无物料行整棵 BOM 树不再渲染（更不会渲染资料错误态）。

      await _openBucketDetail(tester, 'workshop');
      expect(find.text('测试产品'), findsOneWidget);
      expect(find.text('第二测试产品'), findsOneWidget);
      final directRow = find
          .ancestor(of: find.text('测试产品').first, matching: find.byType(Row))
          .first;
      final materialBackedRow = find
          .ancestor(of: find.text('第二测试产品').first, matching: find.byType(Row))
          .first;
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: directRow, matching: find.byType(TextField)),
            )
            .controller
            ?.text,
        '10',
      );
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: materialBackedRow,
                matching: find.byType(TextField),
              ),
            )
            .controller
            ?.text,
        '6',
      );
      await _closeBucketDetail(tester);
      expect(find.byKey(const Key('material-bom-tree')), findsNothing);
      expect(find.textContaining('生产 BOM 策略'), findsNothing);
      expect(find.textContaining('资料异常'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('下达车间')), findsWidgets);
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'material details distinguish exact node receipt peg from whole-kit readiness',
    (tester) async {
      final analysis = _analysisJson(const ['VIEW']);
      final firstProduct =
          (analysis['products']! as List<dynamic>).first
              as Map<String, dynamic>;
      firstProduct
        ..['readyNowQty'] = 0
        ..['canSchedule'] = false
        ..['maxSchedulableQty'] = 0
        ..['readinessRatio'] = 0;
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

      // 2026-09-04 改版口径：「暂不可生产」卡片状态徽标下线，产品被阻断改为
      // 「暂不可安排」入口计数 = 1 断言；节点级 exact peg 徽标仍在 BOM 树行上。

      expect(find.text('“最多可生产”是整套齐套量；单项合格到货会在下方物料卡显示。'), findsNothing);
      await _openMaterialTableDetails(tester, 'material-path-1');
      expect(find.text('本节点合格入库绑定 2'), findsOneWidget);
      expect(
        find.byKey(const Key('material-analysis-off-target-warehouse-warning')),
        findsNothing,
      );
      await _closeMaterialTableDetails(tester);
      await _openMaterialTableDetails(tester, 'material-path-2');
      expect(find.text('本节点合格入库绑定 2'), findsNothing);
    },
  );

  testWidgets(
    'completed demand separates exact receipt from public safety replenishment',
    (tester) async {
      final analysis = _buySelectionAnalysisJson();
      final firstProduct =
          (analysis['products']! as List<dynamic>).first
              as Map<String, dynamic>;
      firstProduct
        ..['readyNowQty'] = 0
        ..['canSchedule'] = false
        ..['maxSchedulableQty'] = 0
        ..['readinessRatio'] = 0;
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
        ..['mainWarehousePublicAvailableQty'] = 0
        ..['mainWarehouseOpenSafetySupplyQty'] = 0
        ..['mainWarehouseSafetyReplenishmentGapQty'] = 100000
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

      await _openMaterialTableDetails(tester, 'buy-line-1');
      expect(find.text('本节点合格入库绑定 1000'), findsOneWidget);
      expect(find.text('合格库存保障 1000/1000(100%)'), findsOneWidget);
      expect(find.text('安全保护 100000'), findsOneWidget);
      expect(find.text('公共补库待补 100000'), findsOneWidget);
      await _closeMaterialTableDetails(tester);
      expect(find.textContaining('本批需求已覆盖 · 公共补库在途 0'), findsOneWidget);
    },
  );

  testWidgets(
    'planning does not expose subwarehouse stock positions across BOM roots',
    (tester) async {
      final analysis = _analysisJson(const ['VIEW']);
      final materials = (analysis['flatMaterials']! as List<dynamic>)
          .cast<Map<String, dynamic>>();
      materials[1]['analysisLineId'] = 'product-line-2';
      for (final material in materials.take(2)) {
        // The API's analysis-wide SKU/warehouse total repeats across roots.
        // A location row represents that total once, not one total per BOM node.
        material['warehouseBreakdown'] = [
          {
            'warehouseId': 'warehouse-1',
            'warehouseName': '主仓',
            'onHandQty': 0,
            'availableQty': 0,
            'ownPeggedQty': 0,
          },
          {
            'warehouseId': 'warehouse-2',
            'warehouseName': '委外收货仓',
            'onHandQty': 2,
            'availableQty': 2,
            'ownPeggedQty': 2,
          },
        ];
      }
      // A later root may be the first response row carrying another location.
      (materials[1]['warehouseBreakdown'] as List<dynamic>).add({
        'warehouseId': 'warehouse-3',
        'warehouseName': '成品子仓',
        'onHandQty': 3,
        'availableQty': 3,
        'ownPeggedQty': 3,
      });
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
        find.byKey(const Key('material-analysis-stock-locations')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('material-analysis-issue-warehouse-settings')),
        findsNothing,
      );
      expect(find.text('物料存放位置'), findsNothing);
      expect(find.text('共享紧固件(M-1)：委外收货仓 2 个'), findsNothing);
      expect(find.text('共享紧固件(M-1)：成品子仓 3 个'), findsNothing);
      expect(find.textContaining('不计入备料'), findsNothing);
      expect(find.textContaining('红冲'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final selectedByServer in [true, false]) {
    testWidgets(
      'planning main totals keep qualified quantities from ${selectedByServer ? 'same main warehouse children' : 'proven external source warehouses'}',
      (tester) async {
        final analysis = _analysisJson(const ['VIEW']);
        analysis['analysisId'] = '6b03a2cd-1147-4776-a0ad-a8be9d7fb01b';
        analysis['warehouseId'] = 'warehouse-planned';
        analysis['warehouseIds'] = ['warehouse-planned'];
        analysis['warehouses'] = [
          {
            'warehouseId': 'warehouse-planned',
            'warehouseName': '原材料不良仓',
            'selected': true,
            'primary': true,
          },
          {
            'warehouseId': 'warehouse-finished',
            'warehouseName': '成品仓库',
            'selected': selectedByServer,
          },
          {
            'warehouseId': 'warehouse-track',
            'warehouseName': '轨道车间',
            'selected': selectedByServer,
          },
        ];
        // Reproduce the user's confirmed server projection: 5 / 10000 / 20000,
        // all allocated, no physical gap, despite different leaf warehouse UUIDs.
        final samples = [
          (
            code: 'UT3015',
            qty: 5,
            warehouse: 'warehouse-finished',
            name: '成品仓库',
          ),
          (
            code: 'UT1090',
            qty: 10000,
            warehouse: 'warehouse-track',
            name: '轨道车间',
          ),
          (
            code: 'V51150',
            qty: 20000,
            warehouse: 'warehouse-finished',
            name: '成品仓库',
          ),
        ];
        analysis['flatMaterials'] = [
          for (final sample in samples)
            {
              ..._materialJson(
                id: sample.code,
                level: 1,
                path: ['测试产品', sample.code],
                routeConfirmed: true,
              ),
              'goodsId': 'goods-${sample.code}',
              'materialKey': 'goods-${sample.code}|NONE|unit-1',
              'goodsCode': sample.code,
              'goodsName': null,
              'requiredQty': sample.qty,
              'availableQty': sample.qty,
              'allocatedAvailableQty': sample.qty,
              'exactPeggedQty': sample.qty,
              'selectedWarehousesAvailableQty': sample.qty,
              'shortageQty': 0,
              'demandSupplyGapQty': 0,
              'warehouseBreakdown': [
                {
                  'warehouseId': sample.warehouse,
                  'warehouseName': sample.name,
                  'onHandQty': sample.qty,
                  'availableQty': sample.qty,
                  'ownPeggedQty': sample.qty,
                },
              ],
            },
        ];
        await _pumpPage(
          tester,
          size: selectedByServer
              ? const Size(1200, 1000)
              : const Size(600, 1000),
          theme: selectedByServer ? ThemeData.light() : ThemeData.dark(),
          permissions: const {
            Perm.productionMaterialAnalysisCreate,
            Perm.productionMaterialAnalysisRefresh,
          },
          analysisId: '6b03a2cd-1147-4776-a0ad-a8be9d7fb01b',
          analysisJson: analysis,
          responseOverride: (request) =>
              request.method == 'GET' &&
                  request.path ==
                      '/production/material-analyses/6b03a2cd-1147-4776-a0ad-a8be9d7fb01b'
              ? analysis
              : null,
          warehouseEntries: const [
            {'id': 'main-warehouse', 'name': '公司主仓'},
            {
              'id': 'warehouse-planned',
              'name': '原材料不良仓',
              'parentId': 'main-warehouse',
            },
            {
              'id': 'warehouse-finished',
              'name': '成品仓库',
              'parentId': 'main-warehouse',
            },
            {
              'id': 'warehouse-track',
              'name': '轨道车间',
              'parentId': 'main-warehouse',
            },
          ],
        );
        expect(find.textContaining('不计入备料'), findsNothing);
        expect(find.textContaining('重新登记'), findsNothing);
        expect(
          find.byKey(
            const Key('material-analysis-off-target-warehouse-warning'),
          ),
          findsNothing,
        );
        expect(find.text('物料存放位置'), findsNothing);
        expect(find.text('成品仓库'), findsNothing);
        expect(find.text('轨道车间'), findsNothing);
        final main = tester.widget<UtenDropdownField>(
          find.byKey(
            const ValueKey('material-analysis-main-warehouse-main-warehouse'),
          ),
        );
        expect(main.value, 'main-warehouse');
        expect(main.items.map((item) => item.value), ['main-warehouse']);
        await _openMaterialTableDetails(tester, 'UT3015');
        expect(find.text('合格库存保障 5/5(100%)'), findsOneWidget);
        expect(find.text('本节点合格入库绑定 5'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('selected master defaults confirm without an optional reason', (
    tester,
  ) async {
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
    expect(find.text('确认路线(0)'), findsOneWidget);
    expect(
      harness.requests.where((request) => request.method == 'PUT'),
      isEmpty,
    );
    await _createDefaultRoutes(tester);

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
      expect(decision['reason'], isNull);
    }
  });

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
          route: 'SUBCONTRACT',
          allowedActions: const ['CONFIRM_ROUTES'],
        ),
        responseOverride: (request) {
          if (!request.path.endsWith('/routes')) return null;
          routeResponse++;
          return _bulkRouteAnalysisJson(
            count: 501,
            route: 'SUBCONTRACT',
            allowedActions: const ['CONFIRM_ROUTES'],
            version: 3 + routeResponse,
            fingerprintChar: routeResponse == 1 ? 'b' : 'c',
            confirmedCount: routeResponse == 1 ? 500 : 501,
          );
        },
      );

      await _createDefaultRoutes(tester);

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
          route: 'SUBCONTRACT',
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
            route: 'SUBCONTRACT',
            allowedActions: const ['CONFIRM_ROUTES'],
            version: routeAttempt == 1 ? 4 : 5,
            fingerprintChar: routeAttempt == 1 ? 'b' : 'c',
            confirmedCount: routeAttempt == 1 ? 500 : 501,
          );
        },
      );

      await _createDefaultRoutes(tester);
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
          Perm.productionMaterialAnalysisGenerate,
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

      // 2026-09-04 改版口径：树头「批量选择(整次分析)」三枚全选勾下线；
      // 表格分页（200/页）后表头三态只选当页，跨页批量用「全选全部」按钮。
      // 分批/幂等/CAS 断言不变。
      await _openBucketDetail(tester, 'buy');
      final selectAllPage = _bucketHeaderCheckbox();
      expect(tester.widget<Checkbox>(selectAllPage).value, isFalse);
      final selectAllEverything = find.byKey(
        const Key('material-analysis-bucket-select-all'),
      );
      expect(selectAllEverything, findsOneWidget);
      await tester.ensureVisible(selectAllEverything);
      await tester.pumpAndSettle();
      await tester.tap(selectAllEverything);
      await tester.pump();
      final buyNotifyAll = find.text('提交采购需求(501)');
      await tester.ensureVisible(buyNotifyAll);
      await tester.tap(buyNotifyAll);
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

      // 2026-09-04 改版口径：全选/提交入口移入可采购桶详情页；分页（200/页）
      // 后 501 行跨页全选走「全选全部」按钮；失败后余量桶里只剩 1 行可执行
      // 组，重开桶表头全选重提，幂等键断言不变。
      await _openBucketDetail(tester, 'buy');
      final selectAllEverything = find.byKey(
        const Key('material-analysis-bucket-select-all'),
      );
      expect(selectAllEverything, findsOneWidget);
      await tester.ensureVisible(selectAllEverything);
      await tester.pumpAndSettle();
      await tester.tap(selectAllEverything);
      await tester.pump();
      await tester.tap(find.text('提交采购需求(501)'));
      await tester.pumpAndSettle();
      await _confirmSupplyQuantityDialog(tester);

      // 超时的第二分块只剩 1 个组仍可执行（服务端已确认前 500 个）。
      // 2026-09-04：动作完成后留在桶内刷新——先返回宿主页再重开桶核对。
      await _closeBucketDetail(tester);
      await _openBucketDetail(tester, 'buy');
      expect(find.textContaining('下达采购 · 1'), findsOneWidget);
      await tester.tap(_bucketHeaderCheckbox());
      await tester.pump();
      final retryButton = find.text('提交采购需求(1)');
      await tester.ensureVisible(retryButton);
      await tester.tap(retryButton);
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

  testWidgets('MAKE_COMPONENT product stays separate from its blocked parent', (
    tester,
  ) async {
    final json = _analysisJson(const ['PLAN_PREVIEW', 'GENERATE_PLAN']);
    final products = json['products']! as List<dynamic>;
    // Top product is blocked (readyNowQty 0); a self-make sub-assembly is
    // plan-ready and linked back to it.
    (products[0] as Map<String, dynamic>)
      ..['goodsName'] = '顶级插座'
      ..['readyNowQty'] = 0
      ..['canSchedule'] = false
      ..['maxSchedulableQty'] = 0;
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
      'canSchedule': true,
      'maxSchedulableQty': 6,
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

    // 2026-09-04 改版口径：产品/候选大卡片（“用于组装 X”徽标、ready/
    // waiting 分组卡）下线——自底向上的分组现在由分桶表达：自制子件在
    // 「可安排生产」桶（类型列标注自制子件），被阻断的顶级产品在
    // 「暂不可安排」桶，两组互不混排。父项名（用于组装 X）在真实子件行
    // 不再展示，仅候选行保留「订单/上级」列。

    await _openBucketDetail(tester, 'workshop');
    expect(find.text('自制子件A'), findsOneWidget);
    expect(find.text('自制子件'), findsOneWidget);
    await _tapBucketRowCheckbox(tester, '自制子件A');
    expect(_bucketRowCheckboxValue(tester, '自制子件A'), isTrue);
    await _closeBucketDetail(tester);
    await _openBucketDetail(tester, 'workshop', stateFilter: '需处理');
    expect(find.text('顶级插座(P-1)'), findsOneWidget);
  });

  testWidgets(
    'confirmed MAKE with lower-level shortage stays explicit and executable',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(375, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _pendingMakeCandidateAnalysisJson(),
        textScale: 1.3,
      );

      // 下层缺料不再卡自制任务：产品分桶与物料路线分桶互不重复，当前
      // 自制物料只进入「待自制」桶并保持人工显式勾选。

      await _openBucketDetail(tester, 'workshop');
      expect(find.text('待自制壳体'), findsOneWidget);
      // 2026-09-06 统一流程词表：未下达自制任务显示「等待下达车间」。
      // 可勾选+可创建生产计划即证明下层缺料不构成硬卡。
      expect(find.text('等待下达车间'), findsWidgets);
      await _tapBucketRowCheckbox(tester, '待自制壳体');
      expect(_bucketRowCheckboxValue(tester, '待自制壳体'), isTrue);
      expect(find.text('创建生产计划(1)'), findsOneWidget);
      final bucketTable = find.byWidgetPredicate(
        (widget) => widget is UtenEditableGrid<EditableGridRow>,
      );
      expect(bucketTable, findsOneWidget);
      expect(
        find.descendant(of: bucketTable, matching: find.byType(SelectionArea)),
        findsNothing,
      );
      await _closeBucketDetail(tester);
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
    'confirmed SUBCONTRACT with BOM children remains explicitly executable',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(375, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _pendingMakeCandidateAnalysisJson(
          parentRoute: 'SUBCONTRACT',
        ),
      );

      // 有子层委外与自制同构：下层缺料不阻止显式下达，后续计划进入待料。

      _expectBucketCount(tester, 'subcontract', 1);
      await _openBucketDetail(tester, 'subcontract');
      expect(find.text('待自制壳体'), findsOneWidget);
      expect(find.text('等待下发委外'), findsWidgets);
      await _tapBucketRowCheckbox(tester, '待自制壳体');
      expect(find.text('下达委外(1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ready SUBCONTRACT candidate offers checkbox and bottom subcontract action',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _pendingMakeCandidateAnalysisJson(
          parentRoute: 'SUBCONTRACT',
          lowerLevelPending: false,
        ),
      );

      // 齐套委外候选归「可委外」路线桶，不再与产品排产行重复。

      _expectBucketCount(tester, 'subcontract', 1);
      await _openBucketDetail(tester, 'subcontract');
      expect(find.text('待自制壳体'), findsOneWidget);
      expect(find.textContaining('本批需求待通知'), findsOneWidget);
      await _tapBucketRowCheckbox(tester, '待自制壳体');
      expect(_bucketRowCheckboxValue(tester, '待自制壳体'), isTrue);
      expect(find.text('下达委外(1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'SUBCONTRACT_MAKE child has no second BOM root and no standalone section',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _pendingMakeCandidateAnalysisJson(
          parentRoute: 'SUBCONTRACT',
          includeRealChild: true,
          childSourceType: 'SUBCONTRACT_MAKE',
        ),
      );

      // 2026-09-03 收口：委外子件与自制完全同构——不在页面下方重复开
      // 「委外件前置自制」独立区块，也不在 BOM 树新开第二个产品根。
      expect(find.text('委外件前置自制'), findsNothing);
      expect(
        find.byKey(const ValueKey('material-bom-product-pending-make-child-1')),
        findsNothing,
      );
      // 子件身份只在分桶行表达一次：候选已被真实子件替代（waiting 桶里是
      // 子件产品行，不再有候选行）。

      await _openBucketDetail(tester, 'workshop', stateFilter: '需处理');
      expect(find.textContaining('待自制壳体(自制备料)'), findsOneWidget);
      expect(find.text('待自制壳体'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ready MAKE task is selectable in the dedicated make bucket', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
        Perm.productionMaterialAnalysisNotify,
      },
      analysisJson: _pendingMakeCandidateAnalysisJson(lowerLevelPending: false),
    );

    await _openBucketDetail(tester, 'workshop');
    // 2026-09-06 统一流程词表：未下达候选行显示「等待下达车间」。
    expect(find.text('等待下达车间'), findsWidgets);
    await _tapBucketRowCheckbox(tester, '待自制壳体');
    expect(_bucketRowCheckboxValue(tester, '待自制壳体'), isTrue);
    expect(find.text('创建生产计划(1)'), findsOneWidget);
  });

  testWidgets('non-actionable MAKE remains read-only in the waiting bucket', (
    tester,
  ) async {
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
    );

    // 2026-09-04 改版口径：执行门禁关闭（actionable=false）的候选即使
    // 下层齐套也不进可安排桶，留在「暂不可安排」且不可勾选（整页无勾选框）。

    await _openBucketDetail(tester, 'workshop', stateFilter: '需处理');
    expect(find.text('待自制壳体'), findsOneWidget);
    expect(find.text('当前状态不可创建'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets(
    'route preparation preserves pending blocked and issued tasks across layouts',
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
        ..['canSchedule'] = false
        ..['maxSchedulableQty'] = 0
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
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: analysis,
        theme: theme,
        textScale: 1.3,
      );

      // Route entries keep issue state inside the same workflow.
      for (final route in ['buy', 'subcontract', 'workshop']) {
        expect(
          find.byKey(Key('material-analysis-entry-$route')),
          findsOneWidget,
        );
      }
      _expectBucketCount(tester, 'workshop', 5);

      await _openBucketDetail(tester, 'workshop');
      expect(find.text('第二测试产品'), findsOneWidget);
      // ADR-71：产品行默认数量 = 剩余需求 = 6（齐套上限不再预填）。
      final readyProductRow = find
          .ancestor(of: find.text('第二测试产品'), matching: find.byType(Row))
          .first;
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: readyProductRow,
                matching: find.byType(TextField),
              ),
            )
            .controller
            ?.text,
        '6',
      );
      await _closeBucketDetail(tester);

      await _openBucketDetail(tester, 'workshop', stateFilter: '需处理');
      expect(find.text('测试产品(P-1)'), findsOneWidget);
      // 暂不可安排桶只读：无任何勾选框与计划输入。
      expect(find.byType(Checkbox), findsNothing);
      await _closeBucketDetail(tester);

      await _openBucketDetail(tester, 'workshop');
      expect(find.text('待自制壳体'), findsOneWidget);
      expect(find.text('已齐套自制件'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('待自制壳体')).dy,
        lessThan(tester.getTopLeft(find.text('已齐套自制件')).dy),
      );
      await _closeBucketDetail(tester);

      await _openBucketDetail(tester, 'workshop', stateFilter: '已下达');
      expect(find.textContaining('已下达产品'), findsOneWidget);
      expect(find.text('物料齐套 · 可开工'), findsOneWidget);
      await _closeBucketDetail(tester);

      // 紧凑屏同样以入口 + 详情页承载分组（旧卡片布局断言迁移）。
      tester.view.physicalSize = const Size(375, 900);
      await tester.pumpAndSettle();

      await _openBucketDetail(tester, 'workshop');
      expect(find.text('第二测试产品'), findsOneWidget);
      await _closeBucketDetail(tester);
      await _openBucketDetail(tester, 'workshop', stateFilter: '需处理');
      expect(find.text('测试产品(P-1)'), findsOneWidget);
      await _closeBucketDetail(tester);
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

    // 2026-09-04 改版口径：候选卡/产品卡下线——候选被真实子件替代（暂不可
    // 安排桶里只有子件产品行，没有候选行），父产品仍在可安排桶。

    await _openBucketDetail(tester, 'workshop', stateFilter: '需处理');
    expect(find.textContaining('待自制壳体(自制备料)'), findsOneWidget);
    expect(find.text('待自制壳体'), findsNothing);
    await _closeBucketDetail(tester);
    await _openBucketDetail(tester, 'workshop');
    expect(find.text('测试产品(P-1)'), findsOneWidget);
    expect(find.text('第二测试产品(P-2)'), findsOneWidget);
  });

  testWidgets('MAKE bucket keeps all 21 tasks reachable', (tester) async {
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

    // 路线任务使用「待自制」分页表格，21 个任务均可检索和滚动抵达。

    await _openBucketDetail(tester, 'workshop');
    expect(find.text('待自制件 1'), findsOneWidget);
    await _scrollBucketRowVisible(tester, '待自制件 21');
    expect(find.text('待自制件 21'), findsOneWidget);
    expect(
      find.byKey(const Key('material-analysis-show-more-pending-make')),
      findsNothing,
    );
  });

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

      final firstRow = await _materialTableRowVisible(
        tester,
        'material-path-1',
      );
      final secondRow = await _materialTableRowVisible(
        tester,
        'material-path-2',
      );
      expect(find.textContaining('涉及 2 条路径'), findsNothing);
      expect(
        find.descendant(
          of: firstRow,
          matching: find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
        ),
        findsNothing,
      );
      // 2026-09-04：主表身份格不再显示 BOM 路径（详情弹窗仍保留完整路径）。
      expect(find.textContaining('路径：'), findsNothing);
      await _openMaterialTableDetails(tester, 'material-path-1');
      final firstDetails = find.byKey(
        const ValueKey('material-node-details-material-path-1'),
      );
      expect(
        find.descendant(
          of: firstDetails,
          matching: find.text('路径：测试产品 → 组件 A → 共享紧固件'),
        ),
        findsOneWidget,
      );
      await _closeMaterialTableDetails(tester);
      await _chooseMaterialRoute(tester, 'material-path-1', '采购');

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
      expect(secondRow, findsOneWidget);
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

      var buyRow = await _materialTableRowVisible(tester, 'material-path-1');
      expect(
        find.descendant(of: buyRow, matching: find.byType(Checkbox)),
        findsOneWidget,
      );
      expect(
        harness.requests.where((request) => request.method == 'PUT'),
        isEmpty,
      );
      await _chooseMaterialRoute(tester, 'material-path-1', '采购');
      expect(
        harness.requests.where((request) => request.method == 'PUT'),
        hasLength(1),
      );
      buyRow = await _materialTableRowVisible(tester, 'material-path-1');
      // 2026-09-10 F2d：已确认且未改动的行没有勾选框（勾了也不计数）；改下拉
      // 成另一路线后勾选框出现并自动勾上，改回已确认值再次消失。
      expect(
        find.descendant(of: buyRow, matching: find.byType(Checkbox)),
        findsNothing,
      );
      await _chooseMaterialRoute(
        tester,
        'material-path-1',
        '委外',
        confirm: false,
      );
      buyRow = await _materialTableRowVisible(tester, 'material-path-1');
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(of: buyRow, matching: find.byType(Checkbox)),
            )
            .value,
        isTrue,
      );
      expect(find.text('确认路线(1)'), findsOneWidget);
      await _chooseMaterialRoute(
        tester,
        'material-path-1',
        '采购',
        confirm: false,
      );
      buyRow = await _materialTableRowVisible(tester, 'material-path-1');
      expect(
        find.descendant(of: buyRow, matching: find.byType(Checkbox)),
        findsNothing,
      );
      expect(find.text('确认路线(0)'), findsOneWidget);
      await _openBucketDetail(tester, 'buy');
      await _tapBucketRowCheckbox(tester, '共享紧固件');
      expect(find.text('提交采购需求(1)'), findsOneWidget);
      await _closeBucketDetail(tester);
      expect(
        harness.requests.where((request) => request.method == 'PUT'),
        hasLength(1),
      );

      final subcontractRow = await _materialTableRowVisible(
        tester,
        'material-path-2',
      );
      expect(
        find.descendant(of: subcontractRow, matching: find.byType(Checkbox)),
        findsOneWidget,
      );
      expect(
        harness.requests.where((request) => request.method == 'PUT'),
        hasLength(1),
      );

      await _chooseMaterialRoute(tester, 'material-path-2', '委外');
      // Refreshing the second route must keep the first BUY group executable
      // (bucket rows come from the same server facts) instead of dropping it.
      expect(
        harness.requests.where((request) => request.method == 'PUT'),
        hasLength(2),
      );
      await _openBucketDetail(tester, 'buy');
      await _tapBucketRowCheckbox(tester, '共享紧固件');
      expect(find.text('提交采购需求(1)'), findsOneWidget);
      await _closeBucketDetail(tester);
      // 委外路线同样在桶详情页勾选批量下达（V458：有子层由服务端转前置自制）。
      await _openBucketDetail(tester, 'subcontract');
      await _tapBucketRowCheckbox(tester, '共享紧固件');
      expect(find.text('下达委外(1)'), findsOneWidget);
    },
  );

  testWidgets(
    'notified SUBCONTRACT keeps its exact document in issued route tasks',
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

      final harness = await _pumpPage(
        tester,
        size: const Size(375, 900),
        permissions: const {Perm.productionMaterialAnalysisView},
        analysisId: 'analysis-1',
        seeded: false,
        analysisJson: analysis,
        theme: ThemeData.dark(),
        textScale: 1.3,
      );

      await _openBucketDetail(tester, 'subcontract', stateFilter: '已下达');
      expect(find.text('委外件一'), findsOneWidget);
      expect(find.textContaining('WW-SQ-001'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      expect(
        find.byKey(const Key('material-analysis-bucket-action-subcontract')),
        findsNothing,
      );
      expect(
        harness.requests.where((request) => request.method != 'GET'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('route override accepts an empty optional reason', (
    tester,
  ) async {
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
    expect(find.byKey(const Key('material-route-reason')), findsNothing);
    final routeRequest = harness.requests.singleWhere(
      (request) => request.method == 'PUT',
    );
    expect(routeRequest.data, {
      'version': 3,
      'fingerprint': 'a' * 64,
      'idempotencyKey': isA<String>(),
      'decisions': [
        {'actionGroupKey': 'action-material-path-1', 'route': 'MAKE'},
      ],
    });
  });

  testWidgets('route draft stays local until explicit confirmation', (
    tester,
  ) async {
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
    await _chooseMaterialRoute(tester, 'material-path-1', '自制', confirm: false);
    await tester.pumpAndSettle();
    expect(
      harness.requests.where((request) => request.method == 'PUT'),
      isEmpty,
    );
    await tester.tap(find.byKey(const Key('material-analysis-create-routes')));
    await tester.pumpAndSettle();
    final routeRequest = harness.requests.singleWhere(
      (request) => request.method == 'PUT',
    );
    expect((routeRequest.data as Map<String, dynamic>)['decisions'], [
      {'actionGroupKey': 'action-material-path-1', 'route': 'MAKE'},
    ]);
  });

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
      await _materialTableRowVisible(tester, 'material-path-1');
      expect(
        find.byKey(const ValueKey('material-route-dropdown-material-path-1')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('material-analysis-create-routes')),
        findsNothing,
      );
      expect(find.byKey(const Key('material-analysis-generate')), findsNothing);
      expect(
        harness.requests.where(
          (request) =>
              request.path.endsWith('/routes') ||
              request.path.endsWith('/notify') ||
              request.path.endsWith('/issue-plans'),
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

      await _openMaterialTableDetails(tester, 'dependency-path-1');
      expect(find.text('本批需求 20'), findsOneWidget);
      expect(find.text('合格库存保障 4/20(20%)'), findsOneWidget);
      expect(find.text('公共可用 7'), findsOneWidget);
      final dependencyDetails = find.byKey(
        const ValueKey('material-node-details-dependency-path-1'),
      );
      expect(
        find.descendant(
          of: dependencyDetails,
          matching: find.text('路径：测试产品 → 自制组件 → 下层依赖件'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('随上级件'), findsNothing);
      expect(
        find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
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

    await _materialTableRowVisible(tester, 'material-path-1');
    await _materialTableRowVisible(tester, 'material-path-2');
    expect(find.textContaining('涉及 2 条路径'), findsNothing);
    expect(
      find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
      findsNothing,
    );
    await _openMaterialTableDetails(tester, 'material-path-1');
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
        ..['shortageQty'] = 0
        ..['demandSupplyGapQty'] = 0
        ..['additionalSupplyRecommendedQty'] = 0;

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
      final completedRow = await _materialTableRowVisible(tester, 'buy-child');
      expect(
        find.descendant(of: completedRow, matching: find.text('已齐套')),
        findsOneWidget,
      );
      // 2026-09-10 F2e：缺口=0 走语义 token（浅色 successText），不是 Material 绿。
      expect(
        tester
            .widgetList<Text>(
              find.descendant(of: completedRow, matching: find.byType(Text)),
            )
            .where(
              (text) =>
                  text.data == '0' &&
                  text.style?.color == UtenColors.successText,
            ),
        isNotEmpty,
      );

      await tester.tap(viewShortage);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('material-table-row-buy-child')),
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
      expect(
        find.byKey(const ValueKey('material-bom-product-product-line-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-table-row-make-path-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-table-row-buy-child')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-table-row-make-path-2')),
        findsNothing,
      );
    },
  );

  // ===== 2026-09-10 表头筛选（F2a/F2a-flow）：稳定桶键、祖先只读上下文、chip 同步、
  // 空态清除筛选 =====

  Map<String, dynamic> unconfirmedBuyChildTree() {
    final json = _makeTreeAnalysisJson();
    (json['flatMaterials'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((material) => material['materialLineId'] == 'buy-child')
      ..['sourceConfirmed'] = null
      ..['routeConfirmed'] = false;
    return json;
  }

  testWidgets(
    'header status filter keeps ancestors as read-only context, syncs chip '
    'counts and clears from the empty state',
    (tester) async {
      final json = unconfirmedBuyChildTree()
        ..['allowedActions'] = const ['VIEW'];
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
      await _materialTableRowVisible(tester, 'buy-child');
      expect(find.text('全部 BOM 3'), findsOneWidget);

      await _selectMaterialHeaderFilter(tester, '进度 / 待办', '路线待确认 (1)');
      // 命中行 + 祖先（产品行 / 自制组件 A）保留为只读上下文；无关行隐藏；
      // chip 计数与表同口径。
      expect(
        find.byKey(const ValueKey('material-table-row-buy-child')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-table-row-make-path-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-bom-product-product-line-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-table-row-make-path-2')),
        findsNothing,
      );
      expect(find.text('上级路径上下文（只读）'), findsWidgets);
      expect(find.text('全部 BOM 1'), findsOneWidget);

      // 关键词只命中被筛掉的行 → 0 行空态：组件层给「清除筛选」出口。
      // 查找框在联动折叠头区里，表格滚动后已收起（offstage）：先回顶再输入。
      await _resetPageScrolls(tester);
      final search = find.byKey(const Key('material-bom-search'));
      await tester.ensureVisible(search);
      await tester.enterText(search, 'MAKE-B');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('当前有 1 个表头筛选生效'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('master-table-clear-filters')),
      );
      await tester.pumpAndSettle();
      expect(find.text('当前有 1 个表头筛选生效'), findsNothing);
      expect(
        find.byKey(const ValueKey('material-table-row-make-path-2')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'switching to the material aggregate view prunes a product-view status filter',
    (tester) async {
      final json = unconfirmedBuyChildTree()
        ..['allowedActions'] = const ['VIEW'];
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
      await _materialTableRowVisible(tester, 'buy-child');
      await _selectMaterialHeaderFilter(tester, '进度 / 待办', '路线待确认 (1)');
      expect(
        find.byKey(const ValueKey('material-table-row-make-path-2')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-material')),
      );
      await tester.pumpAndSettle();
      // 汇总视图的进度桶是三档覆盖率，产品视图的「路线待确认」失效被移除：
      // 三个物料的汇总行全部可见，空态提示不出现。
      expect(find.text('自制组件 A(另一 BOM 路径)'), findsOneWidget);
      expect(find.text('外箱依赖'), findsOneWidget);
      expect(find.text('当前有 1 个表头筛选生效'), findsNothing);
    },
  );

  testWidgets(
    'confirmed rows have no checkbox, header select-all only picks unconfirmed '
    'rows and a blank master source shows a review hint',
    (tester) async {
      final json = unconfirmedBuyChildTree();
      (json['flatMaterials'] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .firstWhere(
                (material) => material['materialLineId'] == 'buy-child',
              )['sourceSuggestion'] =
          null;
      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisRoute,
        },
        allowedActions: const ['CONFIRM_ROUTES', 'NOTIFY_SUPPLY'],
        analysisJson: json,
      );
      final buyChild = await _materialTableRowVisible(tester, 'buy-child');
      expect(
        find.descendant(of: buyChild, matching: find.byType(Checkbox)),
        findsOneWidget,
      );
      // F8：主档来源为空（服务端 REVIEW → 前端 null）时默认委外只是缺省值，
      // 路线格旁给黄标提醒核对。
      expect(
        find.byKey(const ValueKey('material-route-blank-source-buy-child')),
        findsOneWidget,
      );
      final makeRow = await _materialTableRowVisible(tester, 'make-path-1');
      expect(
        find.descendant(of: makeRow, matching: find.byType(Checkbox)),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('material-route-blank-source-make-path-1')),
        findsNothing,
      );
      // 已确认行的下拉仍可改（§3.4 手动草稿优先）。
      expect(
        find.byKey(const ValueKey('material-route-dropdown-make-path-1')),
        findsOneWidget,
      );
      // 表头全选只勾未确认行。
      final header = find.descendant(
        of: find.byKey(const Key('material-analysis-material-table-region')),
        matching: find.byWidgetPredicate((w) => w is Checkbox && w.tristate),
      );
      await tester.ensureVisible(header);
      await tester.pumpAndSettle();
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.text('确认路线(1)'), findsOneWidget);
    },
  );

  testWidgets(
    'a refresh response carrying routeResetCount shows a re-confirm notice',
    (tester) async {
      final json = _makeTreeAnalysisJson()
        ..['allowedActions'] = const ['VIEW', 'REFRESH']
        ..['routeResetCount'] = 2;
      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        allowedActions: const ['VIEW', 'REFRESH'],
        analysisId: 'analysis-1',
        analysisJson: json,
      );
      expect(find.text('2 条路线因主档变更需重新确认'), findsOneWidget);
    },
  );

  testWidgets('waiting product table keeps all 61 rows reachable', (
    tester,
  ) async {
    final json = _analysisJson(const ['VIEW']);
    // 入口计数一次给全，暂不可安排详情表中的全部行都可滚动抵达。
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
            'readyNowQty': 0,
            'canSchedule': false,
            'maxSchedulableQty': 0,
            'readinessRatio': 0,
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

    await _openBucketDetail(tester, 'workshop', stateFilter: '需处理');
    expect(find.text('批量产品 1(BULK-1)'), findsOneWidget);
    await _scrollBucketRowVisible(tester, '批量产品 61(BULK-61)');
    expect(find.text('批量产品 61(BULK-61)'), findsOneWidget);
    expect(
      find.byKey(const Key('material-analysis-show-more-products')),
      findsNothing,
    );
  });

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

      await _scrollToMaterialTable(tester);
      final productToggle = find.byKey(
        const ValueKey('material-table-toggle-PRODUCT|product-line-1'),
      );
      final makeNode = find.byKey(
        const ValueKey('material-table-row-make-path-1'),
      );
      final buyChild = find.byKey(
        const ValueKey('material-table-row-buy-child'),
      );
      await _materialTableRowVisible(tester, 'make-path-1');
      await _materialTableRowVisible(tester, 'buy-child');
      expect(makeNode, findsOneWidget);
      expect(buyChild, findsOneWidget);

      await tester.ensureVisible(productToggle);
      await _resetTableHScroll(tester);
      await tester.tap(productToggle);
      await tester.pumpAndSettle();
      expect(makeNode, findsNothing);
      expect(buyChild, findsNothing);

      await tester.ensureVisible(productToggle);
      await _resetTableHScroll(tester);
      await tester.tap(productToggle);
      await tester.pumpAndSettle();
      await _materialTableRowVisible(tester, 'make-path-1');
      await _materialTableRowVisible(tester, 'buy-child');
      expect(makeNode, findsOneWidget);
      expect(buyChild, findsOneWidget);

      final branchToggle = find.byKey(
        const ValueKey('material-table-toggle-MATERIAL|make-path-1'),
      );
      await tester.tap(branchToggle);
      await tester.pumpAndSettle();
      expect(makeNode, findsOneWidget);
      expect(buyChild, findsNothing);

      await tester.tap(branchToggle);
      await tester.pumpAndSettle();
      await _materialTableRowVisible(tester, 'buy-child');
    },
  );

  testWidgets('route bucket supports tri-state selection and subset notify', (
    tester,
  ) async {
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

    // 三态全选、行选择和批量动作统一由可采购桶的自制表格承载。
    await _openBucketDetail(tester, 'buy');
    final header = _bucketHeaderCheckbox();
    expect(tester.widget<Checkbox>(header).value, isFalse);

    await tester.tap(header);
    await tester.pump();
    expect(tester.widget<Checkbox>(header).value, isTrue);
    expect(find.text('提交采购需求(2)'), findsOneWidget);

    await _tapBucketRowCheckbox(tester, '采购件一');
    expect(tester.widget<Checkbox>(header).value, isNull);
    expect(find.text('提交采购需求(1)'), findsOneWidget);

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
          'publicExtraQty': 0.0,
        },
      ],
    });
    // 采购通知刷新后：已通知行退出可采购桶（三态回到未选），委外路线的
    // 行不受影响、仍可勾选（旧断言的跨路线选择保留改为跨路线可执行保留）。
    // 2026-09-04：分桶动作完成后留在原页刷新——无需重开桶即可断言新行集。
    expect(tester.widget<Checkbox>(_bucketHeaderCheckbox()).value, isFalse);
    await _closeBucketDetail(tester);
    await _openBucketDetail(tester, 'subcontract');
    await _tapBucketRowCheckbox(tester, '委外件一');
    expect(_bucketRowCheckboxValue(tester, '委外件一'), isTrue);
  });

  testWidgets(
    'BUY submit confirm deduplicates safety gap and submits visible two-slice totals',
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

      // 2026-09-05 改版口径：数量修改在分桶表格行内完成（默认=缺口−在途），
      // 点提交只弹「品种数+合计」总结确认；安全缺口去重仍按 goods/color/unit
      // 维度，公共补库作为固定数量并入合计。
      await _openBucketDetail(tester, 'buy');
      final selectAll = _bucketHeaderCheckbox();
      await tester.tap(selectAll);
      await tester.pump();
      // 行内默认量：两行各 8（安全补库是固定切片，不进默认输入值）。
      expect(
        tester
            .widget<TextField>(
              find.byKey(
                const ValueKey(
                  'material-analysis-bucket-submit-qty-buy-action-1',
                ),
              ),
            )
            .controller!
            .text,
        '8',
      );
      final notifyAll = find.text('提交采购需求(2)');
      await tester.ensureVisible(notifyAll);
      await tester.tap(notifyAll);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('supply-submit-confirm-dialog')),
        findsOneWidget,
      );
      expect(find.text('共 2 个品种，合计 22。'), findsOneWidget);
      expect(find.text('本批需求 16 + 公共安全补库 6'), findsOneWidget);
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
          'publicExtraQty': 0.0,
        },
        {
          'actionGroupKey': 'buy-action-2',
          'qty': 8.0,
          'safetyReplenishmentQty': 0.0,
          'publicExtraQty': 0.0,
        },
      ]);
    },
  );

  for (final budget in [
    (available: 12, open: 0, gap: 0),
    (available: 4, open: 2, gap: 4),
  ]) {
    testWidgets(
      'main warehouse budget ignores the default leaf and repeated paths: ${budget.gap}',
      (tester) async {
        final analysis = _buySafetySplitAnalysisJson();
        final rows = (analysis['flatMaterials'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        for (final material in rows.where(
          (row) => row['sourceConfirmed'] == 'BUY',
        )) {
          material
            ..['mainWarehousePublicAvailableQty'] = budget.available
            ..['mainWarehouseOpenSafetySupplyQty'] = budget.open
            ..['mainWarehouseSafetyReplenishmentGapQty'] = budget.gap
            ..['warehouseBreakdown'] = [
              {
                'warehouseId': 'warehouse-1',
                'publicAvailableQty': 0,
                'openSafetySupplyQty': 0,
                'safetyReplenishmentGapQty': 10,
              },
              {
                'warehouseId': 'warehouse-2',
                'publicAvailableQty': budget.available,
                'openSafetySupplyQty': budget.open,
                'safetyReplenishmentGapQty': budget.gap,
              },
            ];
        }
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
        await _openBucketDetail(tester, 'buy');
        await _tapBucketRowCheckbox(tester, '采购件一');
        await _tapBucketRowCheckbox(tester, '采购件二');
        await tester.tap(find.text('提交采购需求(2)'));
        await tester.pumpAndSettle();
        expect(find.text('共 2 个品种，合计 ${16 + budget.gap}。'), findsOneWidget);
        await _confirmSupplyQuantityDialog(tester);
        final request = harness.requests.singleWhere(
          (request) => request.path.endsWith('/notify'),
        );
        final quantities =
            (request.data! as Map<String, dynamic>)['quantities']
                as List<dynamic>;
        expect(
          quantities.map(
            (row) => (row as Map<String, dynamic>)['safetyReplenishmentQty'],
          ),
          [budget.gap.toDouble(), 0.0],
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

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
        ..['mainWarehousePublicAvailableQty'] = 2
        ..['mainWarehouseOpenSafetySupplyQty'] = 2
        ..['mainWarehouseSafetyReplenishmentGapQty'] = 6
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

      final row = await _materialTableRowVisible(tester, 'subcontract-line-1');
      expect(
        find.descendant(of: row, matching: find.text('本版本仅采购路线支持公共安全补库')),
        findsOneWidget,
      );
      // 2026-09-10 F2d：已确认且未改动的行没有勾选框（主表勾选只服务「确认路线」）。
      expect(
        find.descendant(of: row, matching: find.byType(Checkbox)),
        findsNothing,
      );
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

      await _scrollToMaterialTable(tester);
      expect(
        find.byKey(const ValueKey('material-bom-product-product-line-1')),
        findsOneWidget,
      );
      expect(find.text('装配'), findsNothing);
      expect(find.text('发货参考'), findsNothing);
      expect(find.textContaining('涉及 2 条路径'), findsNothing);
      // 行加高后，未进入视口的行在懒加载列表里不会构建，先滚动到可见再断言。
      final make1 = await _materialTableRowVisible(tester, 'make-path-1');
      final buyChild = await _materialTableRowVisible(tester, 'buy-child');
      // DFS：父件 node-make-1 行在子件 node-buy-child 行之上（两行相邻同屏）。
      expect(buyChild, findsOneWidget);
      expect(
        tester.getTopLeft(make1).dy,
        lessThan(tester.getTopLeft(buyChild).dy),
      );
      await _materialTableRowVisible(tester, 'make-path-2');
      // depth>1 缺料件（外箱依赖，层级 2）也可直接操作：进可采购桶勾选提交。
      // （2026-09-04 口径：树行首勾选框下线，改在分桶详情页断言。）
      await _openBucketDetail(tester, 'buy');
      expect(find.text('外箱依赖'), findsOneWidget);
      await _tapBucketRowCheckbox(tester, '外箱依赖');
      expect(_bucketRowCheckboxValue(tester, '外箱依赖'), isTrue);
      await _closeBucketDetail(tester);
      await _openMaterialTableDetails(tester, 'make-path-1');
      expect(find.text('装配'), findsOneWidget);
      await _closeMaterialTableDetails(tester);
      await _openMaterialTableDetails(tester, 'buy-child');
      expect(find.text('发货参考'), findsOneWidget);
    },
  );

  testWidgets(
    'unified tree depth>1 shortage node is actionable (bucket submit and route)',
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

      await _scrollToMaterialTable(tester);
      final depNode = find.byKey(
        const ValueKey('material-table-row-buy-child'),
      );
      expect(depNode, findsOneWidget);
      // 2026-09-10 F2d：已确认（BUY）且未改动的行没有勾选框；行级动作与右键菜单
      // 仍在，批量提交从「可采购」桶内发起。
      expect(
        find.descendant(of: depNode, matching: find.byType(Checkbox)),
        findsNothing,
      );
      expect(find.textContaining('新建采购需求'), findsNothing);

      expect(
        find.byKey(const ValueKey('material-route-dropdown-buy-child')),
        findsOneWidget,
      );
      // Inspecting the dropdown does not write a route or supply request.

      // depth>1 缺料行经分桶批量提交：详情页保持在前台完成总结确认。
      _expectBucketCount(tester, 'buy', 1);
      await _openBucketDetail(tester, 'buy');
      await _tapBucketRowCheckbox(tester, '外箱依赖');
      await tester.tap(find.text('提交采购需求(1)'));
      await tester.pumpAndSettle();
      // 总结确认弹窗叠在分桶详情页之上：宿主页入口（不透明路由下方）不在树中，
      // 详情页 AppBar 标题仍在——不退出回宿主页弹窗。
      expect(
        find.byKey(const Key('supply-submit-confirm-dialog')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('material-analysis-entry-buy')),
        findsNothing,
      );
      expect(find.textContaining('下达采购 · 1'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      // 取消弹窗后仍留在分桶详情页，由用户决定返回。
      expect(find.textContaining('下达采购 · 1'), findsOneWidget);
      await _closeBucketDetail(tester);
    },
  );

  testWidgets(
    'explicit MAKE action creates child and issues its plan with the row inputs',
    (tester) async {
      // 2026-09-05 用户口径：勾选自制候选填「数量/车间/负责人」后点唯一的
      // 「创建生产计划」：显式建子件任务（不自动、下层缺料不构成硬卡），
      // 随后按行内输入直接为新子件生成计划（与自制件同构，不分子层齐套）。
      final initial = _makeTreeAnalysisJson()
        ..['allowedActions'] = const [
          'NOTIFY_SUPPLY',
          'GENERATE_PLAN',
          'PLAN_PREVIEW',
        ];
      final notified = _makeReadyChildAnalysisJson()
        ..['allowedActions'] = const [
          'NOTIFY_SUPPLY',
          'GENERATE_PLAN',
          'PLAN_PREVIEW',
        ];
      final notifiedChild =
          (notified['products']! as List<dynamic>).last as Map<String, dynamic>;
      notifiedChild
        ..['readyNowQty'] = 4
        ..['canSchedule'] = true
        ..['maxSchedulableQty'] = 8;
      // 只保留 make-path-1 一个可显式创建的组，notify 载荷聚焦单组。
      for (final view in [initial, notified]) {
        (view['flatMaterials']! as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .singleWhere(
              (material) => material['materialLineId'] == 'make-path-2',
            )
            .addAll(const {'actionable': false, 'shortageQty': 0});
      }
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
        responseOverride: (request) {
          if (request.path.endsWith('/issue-plans')) {
            return {
              'analysis': notified,
              'plans': [
                {
                  'planId': 'plan-1',
                  'planNo': 'PP-20260905-001',
                  'status': 'DRAFT',
                  'segmentIds': <String>[],
                  'drawIds': <String>[],
                },
              ],
            };
          }
          return null;
        },
      );

      // 自制任务必须由计划员显式勾选下达；打开页面不得自动写入。
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('supply-quantity-dialog')), findsNothing);
      expect(
        harness.requests.where((request) => request.path.endsWith('/notify')),
        isEmpty,
      );

      await _openBucketDetail(tester, 'workshop');
      final candidateRow = find
          .ancestor(of: find.text('自制组件 A'), matching: find.byType(Row))
          .first;
      // 下层只齐套 4 也不影响下达：候选行默认数量=全部剩余 8（齐套拆分由
      // 计划审批后的执行段 WAITING/READY 自动完成）。
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: candidateRow,
                matching: find.byType(TextField),
              ),
            )
            .controller
            ?.text,
        '8',
      );
      await _pickBucketRowWorkshop(tester, candidateRow, '装配一车间');
      await _tapBucketRowCheckbox(tester, '自制组件 A');
      await tester.tap(
        find.byKey(const Key('material-analysis-bucket-action-ready')),
      );
      await tester.pumpAndSettle();

      // 候选直发（ADR-71）：客户端只发一次 issue-plans，子件任务在服务端
      // 同一事务创建（不再有独立的 /notify 与计划预览两段式）。
      final issue = harness.requests.singleWhere(
        (request) => request.path.endsWith('/issue-plans'),
      );
      expect((issue.data! as Map<String, dynamic>)['lines'], [
        {
          'materialLineId': 'make-path-1',
          'qty': 8.0,
          'departmentId': 'workshop-1',
          'workshopName': '装配一车间',
          'workerId': 'worker-1',
        },
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'page load never writes groups whose route is only a suggestion',
    (tester) async {
      // 页面加载绝不隐式创建任务；建议路线仍需计划员显式采用和下达。
      final json = _makeTreeAnalysisJson();
      (json['flatMaterials']! as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .singleWhere(
            (material) => material['materialLineId'] == 'make-path-1',
          )
          .addAll(const {'sourceConfirmed': null, 'routeConfirmed': false});
      (json['flatMaterials']! as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .singleWhere(
            (material) => material['materialLineId'] == 'make-path-2',
          )
          .addAll(const {'actionable': false, 'shortageQty': 0});
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
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        harness.requests.where((request) => request.path.endsWith('/notify')),
        isEmpty,
      );
    },
  );

  testWidgets('page load never auto-notifies a childless subcontract leaf', (
    tester,
  ) async {
    // 无子层委外件必须由员工显式下达，页面加载不产生写请求。
    final json = _makeTreeAnalysisJson();
    final materials = (json['flatMaterials']! as List<dynamic>)
        .cast<Map<String, dynamic>>();
    materials
        .singleWhere((material) => material['materialLineId'] == 'make-path-1')
        .addAll(const {
          'sourceSuggestion': 'SUBCONTRACT',
          'sourceConfirmed': 'SUBCONTRACT',
        });
    materials
        .singleWhere((material) => material['materialLineId'] == 'make-path-2')
        .addAll(const {'actionable': false, 'shortageQty': 0});
    materials.removeWhere(
      (material) => material['materialLineId'] == 'buy-child',
    );
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
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      harness.requests.where((request) => request.path.endsWith('/notify')),
      isEmpty,
    );
  });

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
    final makeRow = await _materialTableRowVisible(tester, 'make-short-1');
    expect(
      find.descendant(of: makeRow, matching: find.text('生产中 · 可报工')),
      findsWidgets,
    );
    await _openMaterialTableDetails(tester, 'make-short-1');
    final details = find.byKey(
      const ValueKey('material-node-details-make-short-1'),
    );
    expect(
      find.descendant(
        of: details,
        matching: find.byKey(const ValueKey('material-view-plan-make-short-1')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: details,
        matching: find.textContaining('PP-MAKE-001'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'completed MAKE keeps quantities workflow and plan deep link in details',
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
        find.byKey(const ValueKey('material-bom-product-child-line-1')),
        findsNothing,
      );

      await _materialTableRowVisible(tester, 'make-short-1');
      await _openMaterialTableDetails(tester, 'make-short-1');
      for (final label in [
        '已下达自制 8',
        '计划量 8',
        '已完工入库 8',
        '生产计划 · SJ-MAKE-DONE-001',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await _closeMaterialTableDetails(tester);
      final workflow = find.byKey(
        const ValueKey('material-table-supply-progress-make-short-1'),
      );
      expect(workflow, findsOneWidget);
      await tester.ensureVisible(workflow);
      await tester.pumpAndSettle();
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
        ..['canSchedule'] = false
        ..['maxSchedulableQty'] = 0
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
      await _materialTableRowVisible(tester, 'make-child-own-material');
      expect(
        find.byKey(
          const ValueKey('material-table-row-make-child-own-material'),
        ),
        findsOneWidget,
      );

      await _openMaterialTableDetails(tester, 'delegated');
      final delegatedDetails = find.byKey(
        const ValueKey('material-node-details-delegated'),
      );
      expect(
        find.descendant(of: delegatedDetails, matching: find.text('状态 · 已完工')),
        findsOneWidget,
      );
      for (final fact in ['已下达自制 12', '计划量 12', '已完工入库 12']) {
        expect(
          find.descendant(of: delegatedDetails, matching: find.text(fact)),
          findsOneWidget,
          reason: fact,
        );
      }
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

    await _openMaterialTableDetails(tester, 'make-short-1');
    final makeRow = find.byKey(
      const ValueKey('material-node-details-make-short-1'),
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
      final firstRound = _planReadyChildAnalysisJson();
      final secondRound = _planReadyChildAnalysisJson(readyNowQty: 1);
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
          if (request.path.endsWith('/issue-plans')) {
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

      // 数量默认在「可安排生产」桶行内（2026-09-04 向导下线）：勾选行、
      // 改数量、滑窗选车间（负责人随之带出车间经理）后直接生成。
      await _openBucketDetail(tester, 'workshop');
      final childRow = find
          .ancestor(of: find.text('自制组件 A(备料任务)'), matching: find.byType(Row))
          .first;
      final qtyField = find
          .descendant(of: childRow, matching: find.byType(TextField))
          .first;
      // ADR-71：数量默认=剩余需求 8（齐套拆批由执行段完成）。
      expect(tester.widget<TextField>(qtyField).controller?.text, '8');
      await _tapBucketRowCheckbox(tester, '自制组件 A(备料任务)');
      await tester.enterText(qtyField, '3');
      await tester.pump();
      await _pickBucketRowWorkshop(tester, childRow, '装配一车间');
      final generateButton = find.byKey(
        const Key('material-analysis-bucket-action-ready'),
      );
      await tester.ensureVisible(generateButton);
      await tester.pumpAndSettle();
      await tester.tap(generateButton);
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

      final issue = harness.requests.singleWhere(
        (request) => request.path.endsWith('/issue-plans'),
      );
      final body = issue.data! as Map<String, dynamic>;
      expect(body['approveNow'], isFalse);
      expect(body['billDate'], '2026-08-09');
      expect(body['deliveryDate'], '2026-08-12');
      // ADR-71：日期在请求顶层提交；行内只带数量+车间+负责人。
      expect(body['lines'], [
        {
          'analysisLineId': 'make-child-ready-1',
          'qty': 3.0,
          'departmentId': 'workshop-1',
          'workshopName': '装配一车间',
          'workerId': 'worker-1',
        },
      ]);
      // A server refresh clears selection: 下达在桶内单次完成，重开可安排桶
      // ——子件行不再预选，数量回到新快照默认值。
      await _openBucketDetail(tester, 'workshop');
      expect(_bucketRowCheckboxValue(tester, '自制组件 A(备料任务)'), isFalse);
      await _closeBucketDetail(tester);
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

      // 2026-09-05 改版口径：数量修改在桶表格行内（默认=本批缺口 8）；
      // 点提交弹总结确认。当前账号没有超量下单权限，公共超量始终为 0。
      await _openBucketDetail(tester, 'buy');
      await _tapBucketRowCheckbox(tester, '采购件一');
      final qtyField = find.byKey(
        const ValueKey('material-analysis-bucket-submit-qty-buy-action-1'),
      );
      expect(tester.widget<TextField>(qtyField).controller!.text, '8');
      // 行内改小成 5 实现分批。
      await tester.enterText(qtyField, '5');
      await tester.pump();
      await tester.ensureVisible(find.text('提交采购需求(1)'));
      await tester.tap(find.text('提交采购需求(1)'));
      await tester.pumpAndSettle();
      expect(find.text('共 1 个品种，合计 5。'), findsOneWidget);
      await tester.tap(find.byKey(const Key('supply-submit-confirm')));
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
          'publicExtraQty': 0.0,
        },
      ]);
      // 2026-09-04：批量动作完成后留在桶内——回到宿主页核对行内文案。
      await _closeBucketDetail(tester);

      // 需求在途 5、本批还差 3：行保持可执行（可采购桶里仍可勾选），
      // 操作列出现「继续提交」。
      final row = await _materialTableRowVisible(tester, 'buy-line-1');
      expect(
        find.descendant(of: row, matching: find.textContaining('需求在途 5')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('本批还差 3')),
        findsOneWidget,
      );
      // 旧「行首勾选框仍在」的口径迁移：分批后该组仍在可采购桶可勾选。
      await _openBucketDetail(tester, 'buy');
      await _tapBucketRowCheckbox(tester, '采购件一');
      expect(_bucketRowCheckboxValue(tester, '采购件一'), isTrue);

      // 补交默认 = 剩余 3（新快照重算后的行内默认值），直接提交。
      final topUpField = find.byKey(
        const ValueKey('material-analysis-bucket-submit-qty-buy-action-1'),
      );
      expect(tester.widget<TextField>(topUpField).controller!.text, '3');
      await tester.tap(find.text('提交采购需求(1)'));
      await tester.pumpAndSettle();
      expect(find.text('共 1 个品种，合计 3。'), findsOneWidget);
      await tester.tap(find.byKey(const Key('supply-submit-confirm')));
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
          'publicExtraQty': 0.0,
        },
      ]);
      expect(notifyCalls, 2);
    },
  );

  testWidgets(
    'approve-now defaults on and shows both submission stages before result',
    (tester) async {
      final issueGate = Completer<void>();
      final secondRound = _planReadyChildAnalysisJson(readyNowQty: 1);
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisGenerate,
          Perm.productionPlanApprove,
        },
        analysisJson: _planReadyChildAnalysisJson(),
        billDate: '2026-08-09',
        deliveryDate: '2026-08-12',
        departmentId: 'workshop-1',
        workshopName: '装配一车间',
        workerId: 'worker-1',
        responseOverride: (request) async {
          if (request.path.endsWith('/issue-plans')) {
            await issueGate.future;
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

      // ADR-71：可安排桶内勾选、滑窗选车间后点「创建生产计划」——单次原子
      // 调用（有审核权限=同事务审核下达），不再有计划预览两段式。
      await _openBucketDetail(tester, 'workshop');
      await _tapBucketRowCheckbox(tester, '自制组件 A(备料任务)');
      final approveRow = find
          .ancestor(of: find.text('自制组件 A(备料任务)'), matching: find.byType(Row))
          .first;
      await _pickBucketRowWorkshop(tester, approveRow, '装配一车间');
      final generateButton = find.byKey(
        const Key('material-analysis-bucket-action-ready'),
      );
      await tester.ensureVisible(generateButton);
      await tester.pump();
      await tester.tap(generateButton);

      // Keep the single request pending so the in-flight overlay is observable
      // and cannot regress to a blank page.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(
        find.byKey(const Key('material-analysis-plan-submission-progress')),
        findsOneWidget,
      );
      expect(find.text('正在生成并审核下达'), findsOneWidget);
      expect(
        harness.requests.where(
          (request) => request.path.endsWith('/issue-plans'),
        ),
        hasLength(1),
      );

      issueGate.complete();
      await tester.pump();
      await tester.pumpAndSettle();

      final issue = harness.requests.singleWhere(
        (request) => request.path.endsWith('/issue-plans'),
      );
      expect((issue.data! as Map<String, dynamic>)['approveNow'], isTrue);

      // 同一屏摆出两张单据：生产计划单 + 物料提货单（领料单）。
      expect(find.text('计划单与提货单已生成'), findsOneWidget);
      expect(find.textContaining('PP-20260809-001'), findsOneWidget);
      expect(find.text('已审核下达'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(
          find.byType(ProductionMaterialAnalysisPage, skipOffstage: false),
        ),
      );
      expect(
        container.read(listRefreshTickProvider(productionExecutionRefreshKey)),
        1,
      );
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
    'issue failure clears submission overlay and surfaces the server error',
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
        analysisJson: _planReadyChildAnalysisJson(),
        billDate: '2026-08-09',
        deliveryDate: '2026-08-12',
        departmentId: 'workshop-1',
        workshopName: '装配一车间',
        workerId: 'worker-1',
        errorOverride: (request) {
          if (!request.path.endsWith('/issue-plans')) return null;
          return DioException(
            requestOptions: request,
            type: DioExceptionType.badResponse,
            response: Response<dynamic>(
              requestOptions: request,
              statusCode: 500,
              data: const {
                'code': 'INTERNAL_ERROR',
                'message': '创建生产计划服务暂时不可用',
              },
            ),
          );
        },
      );

      // ADR-71：桶内单次原子下达；失败后遮罩必须清理并回显服务端错误
      // （事务整体回滚，不会残留「已建子件、未出计划」）。
      await _openBucketDetail(tester, 'workshop');
      await _tapBucketRowCheckbox(tester, '自制组件 A(备料任务)');
      final failRow = find
          .ancestor(of: find.text('自制组件 A(备料任务)'), matching: find.byType(Row))
          .first;
      await _pickBucketRowWorkshop(tester, failRow, '装配一车间');
      final failGenerate = find.byKey(
        const Key('material-analysis-bucket-action-ready'),
      );
      await tester.ensureVisible(failGenerate);
      await tester.pumpAndSettle();
      await tester.tap(failGenerate);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('material-analysis-plan-submission-progress')),
        findsNothing,
      );
      expect(
        harness.requests.where(
          (request) => request.path.endsWith('/issue-plans'),
        ),
        hasLength(1),
      );
      // 页面回到可操作状态：生成是终态动作已返回宿主页（遮罩消失），
      // 可安排桶入口仍在，重试不残留子件行（服务端整体回滚）。
      expect(find.text('填写生产计划单'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('material-analysis-entry-workshop')),
          matching: find.text('下达车间'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'multi-plan result batches 51 printable plans and keeps later batch reachable',
    (tester) async {
      var failLastWorkCardOnce = true;
      final secondRound = _planReadyChildAnalysisJson(readyNowQty: 1);
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisGenerate,
          Perm.productionPlanApprove,
        },
        analysisJson: _planReadyChildAnalysisJson(),
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
          if (request.path.endsWith('/issue-plans')) {
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

      // ADR-71：桶内单次下达；51 张计划的分批与重读断言不变。
      await _openBucketDetail(tester, 'workshop');
      await _tapBucketRowCheckbox(tester, '自制组件 A(备料任务)');
      final batchRow = find
          .ancestor(of: find.text('自制组件 A(备料任务)'), matching: find.byType(Row))
          .first;
      await _pickBucketRowWorkshop(tester, batchRow, '装配一车间');
      final batchGenerate = find.byKey(
        const Key('material-analysis-bucket-action-ready'),
      );
      await tester.ensureVisible(batchGenerate);
      await tester.pumpAndSettle();
      await tester.tap(batchGenerate);
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

  testWidgets('waiting bucket shows shortage kinds and BOM path count', (
    tester,
  ) async {
    final analysis = _pendingMakeCandidateAnalysisJson();
    final products = (analysis['products'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    products.first
      ..['readyNowQty'] = 0
      ..['canSchedule'] = false
      ..['maxSchedulableQty'] = 0;
    (analysis['flatMaterials'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .first['actionable'] =
        false;
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
      },
      analysisJson: analysis,
    );

    // 2026-09-04 改版口径：产品大卡片（齐套进度条 + 「还缺 N 种物料 · 共
    // N 条 BOM 路径」缺口摘要）下线——缺口种类/路径数摘要改在「暂不可
    // 安排」桶详情行的「阻断摘要」列断言（同一口径：2 种缺料、3 条路径、
    // 3 条待确认）；齐套进度条改由入口计数与树内逐节点保障进度承担。
    await _openBucketDetail(tester, 'workshop', stateFilter: '需处理');
    final blockedRow = find
        .ancestor(of: find.text('待自制壳体'), matching: find.byType(Row))
        .first;
    expect(
      find.descendant(
        of: blockedRow,
        matching: find.text('缺料 2 种 / 3 条路径，其中 3 条路线待确认'),
      ),
      findsOneWidget,
    );
    await _closeBucketDetail(tester);
    // Pending tasks keep blockers in the same route; an unrelated ready product has no blocker.
    await _openBucketDetail(tester, 'workshop');
    final readyRow = find
        .ancestor(of: find.text('第二测试产品(P-2)'), matching: find.byType(Row))
        .first;
    expect(
      find.descendant(of: readyRow, matching: find.textContaining('缺料')),
      findsNothing,
    );
    await _closeBucketDetail(tester);
    await _openMaterialTableDetails(tester, 'pending-make-1');
    expect(find.textContaining('合格库存保障 '), findsWidgets);
  });

  testWidgets('material table detail keeps exact qualified-stock coverage', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
      },
    );
    await _openMaterialTableDetails(tester, 'material-path-1');
    // 本批覆盖只认 max(已分配 3, exact 0)，安全/在途不混成本批已到：3/16=19%。
    expect(find.text('合格库存保障 3/16(19%)'), findsOneWidget);
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

      expect(
        find.byKey(const Key('material-analysis-material-table')),
        findsOneWidget,
      );
      // 同一物料跨两个产品、两条路径聚成一行：需求和合格库存保障加总，
      // 公共现货取共享池快照（各路径同源，不重复计数）。
      final sharedRow = find.byKey(
        const ValueKey('material-aggregate-goods-shared-motor||个'),
      );
      expect(sharedRow, findsOneWidget);
      expect(
        find.descendant(of: sharedRow, matching: find.text('15')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: sharedRow,
          matching: find.bySemanticsLabel('合格库存保障 4/15，百分之 27'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sharedRow, matching: find.text('共享电机')),
        findsOneWidget,
      );
      // 展开前不渲染逐路径明细。
      expect(
        find.byKey(const ValueKey('material-table-row-agg-path-1')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(
          const ValueKey(
            'material-table-toggle-AGGREGATE|goods-shared-motor||个',
          ),
        ),
      );
      await tester.pumpAndSettle();
      final firstPath = find.byKey(
        const ValueKey('material-table-row-agg-path-1'),
      );
      final secondPath = find.byKey(
        const ValueKey('material-table-row-agg-path-2'),
      );
      expect(firstPath, findsOneWidget);
      expect(secondPath, findsOneWidget);
      await _openMaterialTableDetails(tester, 'agg-path-1');
      expect(find.text('合格库存保障 4/10(40%)'), findsOneWidget);
      await _closeMaterialTableDetails(tester);
      await _openMaterialTableDetails(tester, 'agg-path-2');
      expect(find.text('合格库存保障 0/5(0%)'), findsOneWidget);
      await _closeMaterialTableDetails(tester);

      // 勾选两条路径 → 按路线汇总为一次采购提交；任务身份仍逐路径独立。
      // 2026-09-04 改版口径：逐路径勾选移入可采购桶详情页（同名「共享电机」
      // 两行 = 两条独立操作组），用表头全选一次勾选。
      await _openBucketDetail(tester, 'buy');
      await tester.tap(_bucketHeaderCheckbox());
      await tester.pump();
      expect(find.text('已选 2 项'), findsOneWidget);
      expect(find.text('提交采购需求(2)'), findsOneWidget);
      await _closeBucketDetail(tester);
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
      await _openMaterialTableDetails(tester, 'agg-path-1');
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
      await _closeMaterialTableDetails(tester);

      // 服务端重算后：借出方行显示"已被调走 · 调给 第二测试产品"，
      // 借入方行（在第二产品的 BOM 区，需滚动到可见）显示"已调入 · 来自 测试产品"。
      await _openMaterialTableDetails(tester, 'agg-path-1');
      expect(find.textContaining('借出 4 件 · 调给 第二测试产品'), findsOneWidget);
      await _closeMaterialTableDetails(tester);
      await _openMaterialTableDetails(tester, 'agg-path-2');
      expect(find.textContaining('借入 4 件 · 来自 测试产品'), findsOneWidget);
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
    await _openMaterialTableDetails(tester, 'agg-path-1');
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

      await _openMaterialTableDetails(tester, 'agg-path-1');
      expect(
        find.byKey(const ValueKey('material-borrow-revoke-borrow-1')),
        findsNothing,
      );
      await _closeMaterialTableDetails(tester);

      await _openMaterialTableDetails(tester, 'agg-path-2');
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

      await _materialTableRowVisible(tester, 'agg-path-1');
      expect(find.textContaining('优先待补 2 件'), findsOneWidget);
      await _openMaterialTableDetails(tester, 'agg-path-1');
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

    await _materialTableRowVisible(tester, 'agg-path-1');
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

      await _openMaterialTableDetails(tester, 'active-zero');
      final details = find.byKey(
        const ValueKey('material-node-details-active-zero'),
      );
      expect(
        find.descendant(of: details, matching: find.text('本批需求 10')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: details, matching: find.text('合格库存保障 0/10(0%)')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: details, matching: find.textContaining('本批已保障')),
        findsNothing,
      );
      expect(find.bySemanticsLabel('合格库存保障 0/10(0%)'), findsWidgets);
      await _closeMaterialTableDetails(tester);

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
      expect(aggregate, findsOneWidget);
      await tester.ensureVisible(aggregate);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: aggregate,
          matching: find.bySemanticsLabel('合格库存保障 0/10，百分之 0'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(
          const ValueKey(
            'material-table-toggle-AGGREGATE|goods-active-zero||个',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _openMaterialTableDetails(tester, 'active-zero');
      expect(find.text('合格库存保障 0/10(0%)'), findsOneWidget);
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

      final row = await _materialTableRowVisible(tester, 'make-short-1');
      await _openMaterialTableDetails(tester, 'make-short-1');
      for (final label in [
        '本批需求 10',
        '合格库存保障 0/10(0%)',
        '已下达自制 10',
        '计划量 10',
        '已完工入库 0',
        '生产中 · 可报工 0%',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.bySemanticsLabel('生产中 · 可报工 0%'), findsWidgets);
      expect(
        find.descendant(of: row, matching: find.textContaining('本批已保障')),
        findsNothing,
      );
      // 2026-09-04 改版口径：产品执行面板（0% 进度条宽度断言）下线——
      // 子件产品的执行阶段在「已转生产」桶详情行断言；0% 明确写为
      // 「尚未完工入库」，绝不把库存覆盖伪装成完工进度。
      expect(
        find.descendant(of: row, matching: find.text('生产中 · 可报工 0%')),
        findsOneWidget,
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

      final row = await _materialTableRowVisible(tester, 'make-short-1');
      await _openMaterialTableDetails(tester, 'make-short-1');
      expect(find.text('合格库存保障 10/10(100%)'), findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('本批库存已覆盖 · 生产中 · 可报工 0%')),
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

      await _openMaterialTableDetails(tester, 'delegated');
      final row = find.byKey(const ValueKey('material-node-details-delegated'));
      for (final label in [
        '需求已转交自制子任务',
        '本节点不再重复备料',
        '关联自制子任务',
        '需求状态 delegated(自制备料)(REQ-delegated)',
        '状态 · 生产中 · 可报工 0%',
        '已下达自制 12',
        '计划量 12',
        '已完工入库 0',
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
      expect(
        tester
            .getSemantics(
              find.byKey(
                const ValueKey('material-make-child-summary-delegated'),
              ),
            )
            .label,
        contains('已下达自制 12；计划量 12；已完工入库 0'),
      );

      final details = find.byKey(
        const ValueKey('material-node-details-delegated'),
      );
      expect(
        find.descendant(
          of: details,
          matching: find.text('需求状态 delegated(自制备料)(REQ-delegated)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: details, matching: find.text('公共可用 0')),
        findsNothing,
      );
      await _closeMaterialTableDetails(tester);

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
      // Zero-demand delegated rows do not inflate material aggregate counts.
      expect(
        find.byKey(const ValueKey('material-aggregate-goods-delegated||个')),
        findsNothing,
      );
      final byProduct = find.byKey(
        const ValueKey('material-bom-layout-product'),
      );
      await tester.ensureVisible(byProduct);
      await tester.tap(byProduct);
      await tester.pumpAndSettle();
      await _openMaterialTableDetails(tester, 'delegated');
      final path = find.byKey(
        const ValueKey('material-node-details-delegated'),
      );
      expect(
        find.descendant(
          of: path,
          matching: find.text('需求状态 delegated(自制备料)(REQ-delegated)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: path, matching: find.text('计划量 12')),
        findsOneWidget,
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
        await _openMaterialTableDetails(tester, entry.key);
        final row = find.byKey(ValueKey('material-node-details-${entry.key}'));
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
        await _closeMaterialTableDetails(tester);
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

      final row = await _materialTableRowVisible(tester, 'make-path-1');
      await _openMaterialTableDetails(tester, 'make-path-1');
      final details = find.byKey(
        const ValueKey('material-node-details-make-path-1'),
      );
      expect(
        find.descendant(of: details, matching: find.text('已下达自制 8')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: details, matching: find.text('关联自制子任务')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: details, matching: find.text('计划量 待回传')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: details, matching: find.text('已完工入库 待回传')),
        findsOneWidget,
      );
      // 2026-09-06 统一流程词表：未下达自制任务一律「等待下达车间」。
      expect(
        find.descendant(of: row, matching: find.text('等待下达车间')),
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

      final exactRow = await _materialTableRowVisible(tester, 'make-exact');
      expect(
        find.descendant(of: exactRow, matching: find.text('生产中 · 可报工 20%')),
        findsOneWidget,
      );

      final missingIdRow = await _materialTableRowVisible(
        tester,
        'make-missing-id',
      );
      expect(
        find.descendant(of: missingIdRow, matching: find.text('等待下达车间')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: missingIdRow,
          matching: find.textContaining('生产中 · 可报工'),
        ),
        findsNothing,
      );
      await _openMaterialTableDetails(tester, 'make-missing-id');
      expect(find.textContaining('计划量'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ready bucket batch buttons render on selection and validate plan inputs',
    (tester) async {
      // 2026-09-04 批量按钮修复回归：UtenEditableGrid select-only 模式不自带
      // 操作条，详情页自管动作条须在勾选后出现并能触发校验。
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: _planReadyChildAnalysisJson(),
      );
      await _openBucketDetail(tester, 'workshop');

      // 未选任何行：批量动作条不出现（0 计数不占位）。
      expect(
        find.byKey(const Key('material-analysis-bucket-action-ready')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('material-analysis-bucket-create-tasks')),
        findsNothing,
      );

      // 勾选可生产子件（数量默认=最多可生产）→ 生成按钮出现并计数 1。
      await _tapBucketRowCheckbox(tester, '自制组件 A(备料任务)');
      expect(_bucketRowCheckboxValue(tester, '自制组件 A(备料任务)'), isTrue);
      final generate = find.byKey(
        const Key('material-analysis-bucket-action-ready'),
      );
      expect(generate, findsOneWidget);
      expect(find.text('创建生产计划(1)'), findsOneWidget);

      // 点生成：数量已默认、车间未选 → 校验拦截，不发起任何计划请求、
      // 留在分桶页（toast 在无通知宿主的 harness 里不渲染，以请求与
      // 页面停留为准）。
      final requestCountBefore = harness.requests.length;
      await tester.ensureVisible(generate);
      await tester.pumpAndSettle();
      await tester.tap(generate);
      await tester.pumpAndSettle();
      expect(
        harness.requests
            .where((request) => request.path.contains('/issue-plans'))
            .length,
        0,
      );
      expect(harness.requests.length, requestCountBefore);
      expect(
        find.byKey(const Key('material-analysis-bucket-entries')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'ready bucket appends more rows without disposing loaded inputs',
    (tester) async {
      final json = _analysisJson(const ['GENERATE_PLAN', 'PLAN_PREVIEW'])
        ..['products'] = [
          for (var index = 1; index <= 101; index++)
            {
              'analysisLineId': 'ready-bulk-$index',
              'sourceType': 'STOCK',
              'sourceRef': 'READY-$index',
              'goodsCode': 'READY-$index',
              'goodsName': '可安排产品 $index',
              'requestedQty': 1,
              'remainingQty': 1,
              'readyNowQty': 1,
              'canSchedule': true,
              'maxSchedulableQty': 1,
              'readinessRatio': 1,
              'allocationPriority': index,
            },
        ]
        ..['flatMaterials'] = <Map<String, dynamic>>[];

      await _pumpPage(
        tester,
        size: const Size(1600, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisGenerate,
        },
        allowedActions: const ['GENERATE_PLAN', 'PLAN_PREVIEW'],
        analysisJson: json,
      );

      await _openBucketDetail(tester, 'workshop');
      expect(find.byType(TextField), findsNWidgets(100));

      final showMore = find.byKey(
        const Key('material-analysis-bucket-show-more'),
      );
      await tester.ensureVisible(showMore);
      await tester.pumpAndSettle();
      await tester.tap(showMore);
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNWidgets(101));
      await tester.enterText(find.byType(TextField).first, '0.5');
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('big analysis opens waiting bucket fast (perf canary)', (
    tester,
  ) async {
    // 性能看门狗：1500 产品 / 3000 物料的大分析，点「暂不可安排」入口
    // 必须在 10 秒内完成。分桶投影原为 O(物料²)（候选×全表扫描），该量级
    // 下要点几十秒（真实环境表现为整页卡死）；2026-09-04 起走
    // (analysisLineId,parentNodeKey) 复合索引 + 分析快照缓存。此用例
    // 超时/超阈值即算法退化。
    final firstInteractiveStopwatch = Stopwatch()..start();
    final harness = await _pumpPage(
      tester,
      size: const Size(1600, 1000),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
      },
      analysisJson: _bigWaitingAnalysisJson(),
    );
    firstInteractiveStopwatch.stop();
    expect(harness, isNotNull);

    expect(
      firstInteractiveStopwatch.elapsed.inSeconds,
      lessThan(10),
      reason: '首屏分桶计数/冷投影退化，页面无法及时交互',
    );
    final stopwatch = Stopwatch()..start();
    await _openBucketDetail(tester, 'workshop', stateFilter: '需处理');
    stopwatch.stop();
    expect(
      find.byKey(const Key('material-analysis-bucket-entries')),
      findsNothing,
    ); // 已进详情页
    expect(
      find.descendant(
        of: find.byType(Scaffold),
        matching: find.textContaining('下达车间 · 1500'),
      ),
      findsOneWidget,
    );
    expect(find.text('/ 8'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '1',
    );
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '2',
    );
    expect(
      stopwatch.elapsed.inSeconds,
      lessThan(10),
      reason: '分桶投影/渲染退化为全表平方扫描',
    );
  });

  testWidgets(
    'partial-ready root product defaults the bucket plan quantity to the complete-kit first batch',
    (tester) async {
      final analysis = _analysisJson(const ['PLAN_PREVIEW', 'GENERATE_PLAN']);
      final product =
          (analysis['products']! as List<dynamic>).first
              as Map<String, dynamic>;
      product
        ..['requestedQty'] = 1000
        ..['remainingQty'] = 1000
        ..['readyNowQty'] = 500
        ..['canSchedule'] = true
        ..['maxSchedulableQty'] = 1000;
      analysis
        ..['products'] = [product]
        ..['flatMaterials'] = <Map<String, dynamic>>[];

      await _pumpPage(
        tester,
        size: const Size(1280, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: analysis,
      );

      await _openBucketDetail(tester, 'workshop');
      // ADR-71：齐套列（建议首批/当前齐套/可排产上限）随「计划不管齐套」
      // 下线；数量默认=剩余需求 1000（齐套拆批由执行段 WAITING/READY 完成）。
      expect(find.text('建议首批'), findsNothing);
      expect(find.text('当前齐套'), findsNothing);
      expect(find.text('等待下达车间'), findsWidgets);
      final productRow = find
          .ancestor(of: find.text('测试产品').first, matching: find.byType(Row))
          .first;
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: productRow, matching: find.byType(TextField)),
            )
            .controller
            ?.text,
        '1000',
      );
    },
  );

  testWidgets(
    'analysis refresh preserves a planner-entered batch quantity while suggestions change',
    (tester) async {
      var previewCalls = 0;
      Map<String, dynamic> state({
        required double ready,
        required double cap,
        required int version,
      }) {
        final json = _analysisJson(const [
          'REFRESH',
          'PLAN_PREVIEW',
          'GENERATE_PLAN',
        ]);
        final product =
            (json['products']! as List<dynamic>).first as Map<String, dynamic>;
        product
          ..['requestedQty'] = 1200
          ..['remainingQty'] = 1200
          ..['readyNowQty'] = ready
          ..['canSchedule'] = true
          ..['maxSchedulableQty'] = cap;
        return json
          ..['version'] = version
          ..['fingerprint'] = (version == 3 ? 'a' : 'b') * 64
          ..['products'] = [product]
          ..['flatMaterials'] = <Map<String, dynamic>>[];
      }

      await _pumpPage(
        tester,
        size: const Size(1280, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisGenerate,
        },
        allowedActions: const ['REFRESH', 'PLAN_PREVIEW', 'GENERATE_PLAN'],
        responseOverride: (request) {
          if (request.method != 'POST' ||
              request.path != '/production/material-analyses/preview') {
            return null;
          }
          previewCalls++;
          return previewCalls == 1
              ? state(ready: 500, cap: 1000, version: 3)
              : state(ready: 700, cap: 1200, version: 4);
        },
      );

      await _openBucketDetail(tester, 'workshop');
      final firstRow = find
          .ancestor(of: find.text('测试产品').first, matching: find.byType(Row))
          .first;
      final firstQty = find.descendant(
        of: firstRow,
        matching: find.byType(TextField),
      );
      await tester.enterText(firstQty, '333');
      await tester.pump();
      await _closeBucketDetail(tester);

      await tester.tap(find.byTooltip('按最新库存刷新分析'));
      await tester.pumpAndSettle();
      expect(previewCalls, 2);

      await _openBucketDetail(tester, 'workshop');
      final refreshedRow = find
          .ancestor(of: find.text('测试产品').first, matching: find.byType(Row))
          .first;
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: refreshedRow,
                matching: find.byType(TextField),
              ),
            )
            .controller
            ?.text,
        '333',
      );
      // ADR-71：建议首批列已下线（计划不管齐套），刷新后手填数量仍保留。
      expect(find.text('建议首批'), findsNothing);
    },
  );

  testWidgets(
    'server-authorized waiting product stays schedulable at remaining qty',
    (tester) async {
      final analysis = _analysisJson(const ['PLAN_PREVIEW', 'GENERATE_PLAN']);
      final product =
          (analysis['products']! as List<dynamic>).first
              as Map<String, dynamic>;
      product
        ..['readyNowQty'] = 0
        ..['remainingQty'] = 10
        ..['canSchedule'] = true
        ..['maxSchedulableQty'] = 10;
      product.remove('scheduleBlockedReason');
      analysis
        ..['products'] = [product]
        ..['flatMaterials'] = <Map<String, dynamic>>[];

      await _pumpPage(
        tester,
        size: const Size(1280, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: analysis,
      );

      await _openBucketDetail(tester, 'workshop');
      // 2026-09-05 顶层与子层自制同构：服务端授权的待料产品仍可全额排产，
      // 未下达统一「等待下达车间」（齐套由执行段自动判断）。
      expect(find.text('等待下达车间'), findsWidgets);
      final productRow = find
          .ancestor(of: find.text('测试产品').first, matching: find.byType(Row))
          .first;
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: productRow, matching: find.byType(TextField)),
            )
            .controller
            ?.text,
        '10',
      );
    },
  );

  testWidgets(
    'material-table-right-click keeps route selection after viewing details',
    (tester) async {
      // 2026-09-10 F2d：已确认且未改动的行没有勾选框，本用例的勾选主体改为
      // 未确认的 buy-child（建议路线仍为 BUY，右键菜单同样带「提交采购需求」）。
      final json = _makeTreeAnalysisJson();
      (json['flatMaterials'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .firstWhere((material) => material['materialLineId'] == 'buy-child')
        ..['sourceConfirmed'] = null
        ..['routeConfirmed'] = false;
      await _pumpPage(
        tester,
        size: const Size(1440, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: json,
      );

      await _scrollToMaterialTable(tester);
      final row = find.byKey(const ValueKey('material-table-row-buy-child'));
      expect(row, findsOneWidget);

      // 横滚后行内会多出一份「冻结列」跟手副本（UtenFrozenLeadingColumn：
      // 勾选框钉在视口左缘），故按 .first 取行内原位那一个。
      final selection = find
          .descendant(of: row, matching: find.byType(Checkbox))
          .first;
      await tester.tap(selection);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(selection).value, isTrue);
      await _rightClickMaterialTableRow(tester, row);
      expect(find.text('查看物料详情'), findsOneWidget);
      expect(find.text('更换供料路线'), findsNothing);
      expect(find.text('采用公共在途'), findsOneWidget);
      expect(find.text('提交采购需求'), findsOneWidget);
      // 右键菜单直接对行生效；未确认行的勾选框与勾选态保留
      //（行内原位 + 冻结副本，至少一个在）。
      expect(
        find.descendant(of: row, matching: find.byType(Checkbox)),
        findsWidgets,
      );

      await tester.tap(find.text('查看物料详情'));
      await tester.pumpAndSettle();
      expect(find.text('外箱依赖'), findsWidgets);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(row, findsOneWidget);
      expect(tester.widget<Checkbox>(selection).value, isTrue);
    },
  );

  testWidgets(
    'material-table-lower-level-pending MAKE remains an explicit executable task',
    (tester) async {
      final json = _makeTreeAnalysisJson();
      for (final material
          in (json['flatMaterials']! as List<dynamic>)
              .cast<Map<String, dynamic>>()) {
        material['lowerLevelPending'] = true;
      }
      final harness = await _pumpPage(
        tester,
        size: const Size(1440, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: json,
      );

      await _scrollToMaterialTable(tester);
      final row = find.byKey(const ValueKey('material-table-row-make-path-1'));
      expect(row, findsOneWidget);
      // 2026-09-05 简化（ADR-71 后续）：MAKE 行菜单退役「创建自制子件任务」——
      // 统一走「下达车间」桶的「创建生产计划」单次原子下达（不再发 /notify）。
      await _rightClickMaterialTableRow(tester, row);
      expect(find.text('创建自制子件任务'), findsNothing);
      expect(
        harness.requests.where(
          (candidate) => candidate.path.endsWith('/notify'),
        ),
        isEmpty,
      );
      // 2026-09-10 F2d：已确认（MAKE）且未改动的行没有勾选框；右键菜单不依赖、
      // 也不产生任何勾选态。
      expect(
        find.descendant(of: row, matching: find.byType(Checkbox)),
        findsNothing,
      );
    },
  );

  testWidgets('BUY over-order splits exact demand 500 from public extra 1500', (
    tester,
  ) async {
    final analysis = _buySelectionAnalysisJson()
      ..['allowedActions'] = const ['NOTIFY_SUPPLY', 'OVER_SUPPLY'];
    final materials = (analysis['flatMaterials'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final first = materials.singleWhere(
      (material) => material['materialLineId'] == 'buy-line-1',
    );
    first
      ..['requiredQty'] = 500
      ..['allocatedAvailableQty'] = 0
      ..['availableQty'] = 0
      ..['shortageQty'] = 500
      ..['demandSupplyGapQty'] = 500
      ..['additionalSupplyRecommendedQty'] = 500
      ..['warehouseBreakdown'] = [
        {
          'warehouseId': 'warehouse-1',
          'publicAvailableQty': 0,
          'openSafetySupplyQty': 0,
          'safetyReplenishmentGapQty': 0,
        },
      ];
    for (final material in materials.skip(1)) {
      material
        ..['actionable'] = false
        ..['shortageQty'] = 0
        ..['demandSupplyGapQty'] = 0;
    }

    final harness = await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
        Perm.productionMaterialAnalysisNotify,
        Perm.productionMaterialAnalysisOverSupply,
      },
      allowedActions: const ['NOTIFY_SUPPLY', 'OVER_SUPPLY'],
      analysisJson: analysis,
    );

    _expectBucketCount(tester, 'buy', 1);
    await _openBucketDetail(tester, 'buy');
    await _tapBucketRowCheckbox(tester, '采购件一');

    // 行内编辑 2000（默认 500）；有超量权限允许超过缺口。
    final qty = find.byKey(
      const ValueKey('material-analysis-bucket-submit-qty-buy-action-1'),
    );
    expect(tester.widget<TextField>(qty).controller!.text, '500');
    await tester.enterText(qty, '2000');
    await tester.pump();
    await tester.tap(find.text('提交采购需求(1)'));
    await tester.pumpAndSettle();

    expect(find.text('共 1 个品种，合计 2000。'), findsOneWidget);
    expect(find.text('本批需求 500 + 公共超量备货 1500'), findsOneWidget);
    await tester.tap(find.byKey(const Key('supply-submit-confirm')));
    await tester.pumpAndSettle();

    final notify = harness.requests.singleWhere(
      (request) => request.path.endsWith('/notify'),
    );
    expect((notify.data! as Map<String, dynamic>)['quantities'], [
      {
        'actionGroupKey': 'buy-action-1',
        'qty': 500.0,
        'safetyReplenishmentQty': 0.0,
        'publicExtraQty': 1500.0,
      },
    ]);
  });

  testWidgets(
    'historical leaf analysis displays only the actual main warehouse and preserves its stored scope',
    (tester) async {
      final analysis = _analysisJson(const ['REFRESH'])
        ..['warehouseIds'] = ['warehouse-1', 'warehouse-2'];
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        analysisId: 'analysis-1',
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        allowedActions: const ['REFRESH'],
        analysisJson: analysis,
        warehouseEntries: const [
          {'id': 'warehouse-root', 'name': '总仓'},
          {'id': 'warehouse-1', 'name': '原主领料仓', 'parentId': 'warehouse-root'},
          {'id': 'warehouse-2', 'name': '备用子仓', 'parentId': 'warehouse-root'},
        ],
      );
      final main = tester.widget<UtenDropdownField>(
        find.byKey(
          const ValueKey('material-analysis-main-warehouse-warehouse-root'),
        ),
      );
      expect(main.value, 'warehouse-root');
      expect(main.items.map((item) => item.value), ['warehouse-root']);
      expect(
        find.byKey(const Key('material-analysis-issue-warehouse-settings')),
        findsNothing,
      );
      expect(find.text('原主领料仓'), findsNothing);
      expect(find.text('备用子仓'), findsNothing);
      await tester.tap(find.byTooltip('按最新库存刷新分析'));
      await tester.pumpAndSettle();
      final request = harness.requests.lastWhere(
        (request) => request.path == '/production/material-analyses/preview',
      );
      final body = request.data! as Map<String, dynamic>;
      expect(body['warehouseId'], 'warehouse-1');
      expect(body['warehouseIds'], ['warehouse-1', 'warehouse-2']);
    },
  );

  testWidgets('new planning request names only the selected main warehouse', (
    tester,
  ) async {
    final harness = await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
      },
      allowedActions: const ['VIEW'],
      analysisJson: _analysisJson(const ['VIEW']),
      warehouseEntries: [
        const {'id': 'warehouse-root', 'name': '总仓'},
        for (var index = 1; index <= 101; index++)
          {
            'id': 'warehouse-$index',
            'name': '子仓$index',
            'parentId': 'warehouse-root',
          },
      ],
    );
    final request = harness.requests.singleWhere(
      (request) => request.path == '/production/material-analyses/preview',
    );
    final body = request.data! as Map<String, dynamic>;
    expect(body['warehouseId'], 'warehouse-root');
    expect(body['warehouseIds'], ['warehouse-root']);
    expect(
      find.byKey(const Key('material-analysis-issue-warehouse-settings')),
      findsNothing,
    );
    expect(find.text('子仓2'), findsNothing);
  });

  testWidgets(
    'planning uses server main totals without inventing a subwarehouse transfer step',
    (tester) async {
      final analysis = _buySelectionAnalysisJson()
        ..['warehouseIds'] = ['warehouse-1', 'warehouse-2'];
      final product =
          (analysis['products']! as List<dynamic>).first
              as Map<String, dynamic>;
      product
        ..['readyNowQty'] = 0
        ..['canSchedule'] = false
        ..['maxSchedulableQty'] = 0
        ..['readinessRatio'] = 0;
      final material =
          (analysis['flatMaterials']! as List<dynamic>).first
              as Map<String, dynamic>;
      material
        ..['requiredQty'] = 1000
        ..['allocatedAvailableQty'] = 0
        ..['shortageQty'] = 1000
        ..['demandSupplyGapQty'] = 1000
        ..['additionalSupplyRecommendedQty'] = 1000
        ..['selectedWarehousesAvailableQty'] = 1500
        ..['selectedOtherWarehouseTransferableQty'] = 1500;

      await _pumpPage(
        tester,
        size: const Size(1440, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        },
        analysisJson: analysis,
      );

      expect(
        find.byKey(const Key('material-analysis-warehouse')),
        findsOneWidget,
      );
      await _scrollToMaterialTable(tester);
      expect(find.textContaining('可调 1500'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              widget.message?.contains('主仓汇总后，当前还需补充 1000。') == true,
        ),
        findsWidgets,
      );
      expect(product['readyNowQty'], 0);
    },
  );

  // 真实数据卡死复现：把开发库抓下来的分析（1 产品 / 13 物料 / 最深 4 层）
  // 原样灌入，逐个打开六张分桶卡。必须在 GoRouter 环境下跑——分桶详情页是
  // 命令式 MaterialPageRoute，其 AppBar 的 PagePermissionAction 在 build 期
  // 调 GoRouterState.of 会向上爬到宿主路由并对 GoRouterStateRegistry 建立
  // 跨路由 inherited 依赖，go_router 14.8 下触发无限重挂载循环（真机点开
  // 即整站卡死）。裸 MaterialApp 复现不了——这就是早期测试全绿的原因。
  testWidgets('real-data freeze repro: open every bucket on captured analysis', (
    tester,
  ) async {
    final fixture =
        jsonDecode(
              File(
                'test/features/production/fixtures/analysis_freeze_repro.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisView,
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
        Perm.productionMaterialAnalysisRoute,
        Perm.productionMaterialAnalysisGenerate,
      },
      allowedActions: const [
        'VIEW',
        'CONFIRM_ROUTES',
        'PLAN_PREVIEW',
        'GENERATE_PLAN',
      ],
      analysisJson: fixture,
      withPlanRoute: true,
    );
    for (final bucket in ['buy', 'subcontract', 'workshop']) {
      final entry = find.byKey(Key('material-analysis-entry-$bucket'));
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      // 计数为 0 的桶入口禁用（点了不进详情页），跳过。
      final enabled =
          (tester.widget<InkWell>(entry).onTap != null) &&
          entry.hitTestable().evaluate().isNotEmpty;
      if (!enabled) {
        debugPrint('[repro] bucket=$bucket disabled, skip');
        continue;
      }
      debugPrint('[repro] opening bucket=$bucket');
      await tester.tap(entry, warnIfMissed: false);
      // 有界等待：卡死时这里超时失败（回归锁）；正常时快速收敛。
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 20),
      );
      debugPrint('[repro] bucket=$bucket settled');
      final back = find.byTooltip('返回');
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back.last, warnIfMissed: false);
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 20),
        );
      }
      debugPrint('[repro] bucket=$bucket closed');
    }
  });
}

Future<void> _scrollToMaterialTable(WidgetTester tester) async {
  // 宽屏（联动滚动）：表格常驻 body，无需整页滚动即可定位。
  // 窄屏（单一滚动区）：表格是 ListView 的惰性子项，需上滑直到构建出来。
  // 不做 ensureVisible——那会把联动头区收起、销毁顶部入口卡。
  final results = find.byKey(const Key('material-analysis-results'));
  for (var attempt = 0; attempt < 10; attempt++) {
    if (find
        .byKey(const Key('material-analysis-material-table-region'))
        .evaluate()
        .isNotEmpty) {
      break;
    }
    await tester.drag(results, const Offset(0, -700));
    await tester.pump();
  }
  expect(
    find.byKey(const Key('material-analysis-material-table-region')),
    findsOneWidget,
  );
  await tester.pump();
}

/// 联动滚动把头区收起后，sliver 惰性构建会销毁入口卡/头部区块——把页面
/// 相关滚动位置全部归位到顶，再定位头区内容。
Future<void> _resetPageScrolls(WidgetTester tester) async {
  final results = find.byKey(const Key('material-analysis-results'));
  final scrollables = find.descendant(
    of: results,
    matching: find.byType(Scrollable),
  );
  for (final state in tester.stateList<ScrollableState>(scrollables)) {
    if (state.position.hasContentDimensions &&
        state.position.pixels > state.position.minScrollExtent) {
      state.position.jumpTo(state.position.minScrollExtent);
    }
  }
  await tester.pumpAndSettle();
}

Future<void> _rightClickMaterialTableRow(
  WidgetTester tester,
  Finder row,
) async {
  final text = find
      .descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              (widget.data?.runes.length ?? 0) > 2 &&
              !RegExp(r'^P\d+(?:\.\d+)*$').hasMatch(widget.data ?? ''),
        ),
      )
      .first;
  await tester.ensureVisible(text);
  await tester.pumpAndSettle();
  final target = tester.getCenter(text);
  final gesture = await tester.startGesture(
    target,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<Finder> _materialTableRowVisible(
  WidgetTester tester,
  String materialLineId,
) async {
  await _scrollToMaterialTable(tester);
  final row = find.byKey(ValueKey('material-table-row-$materialLineId'));
  final region = find.byKey(
    const Key('material-analysis-material-table-region'),
  );
  final tableScroll = find.descendant(
    of: region,
    matching: _verticalScrollable(),
  );
  if (row.evaluate().isEmpty && tableScroll.evaluate().isNotEmpty) {
    final state = tester.state<ScrollableState>(tableScroll.last);
    state.position.jumpTo(0);
    await tester.pump();
    for (var attempt = 0; attempt < 20 && row.evaluate().isEmpty; attempt++) {
      final next = (state.position.pixels + 180).clamp(
        state.position.minScrollExtent,
        state.position.maxScrollExtent,
      );
      if (next == state.position.pixels) break;
      state.position.jumpTo(next);
      await tester.pump();
    }
  }
  expect(row, findsOneWidget);
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  return row;
}

Future<void> _openMaterialTableDetails(
  WidgetTester tester,
  String materialLineId,
) async {
  final row = await _materialTableRowVisible(tester, materialLineId);
  final name = find
      .descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              (widget.data?.runes.length ??
                      widget.textSpan?.toPlainText().runes.length ??
                      0) >
                  2 &&
              !RegExp(
                r'^P\d+(?:\.\d+)*$',
              ).hasMatch(widget.data ?? widget.textSpan?.toPlainText() ?? ''),
        ),
      )
      .first;
  await tester.ensureVisible(name);
  await tester.pumpAndSettle();
  await tester.tapAt(tester.getCenter(name));
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tapAt(tester.getCenter(name));
  await tester.pumpAndSettle();
  expect(
    find.byKey(ValueKey('material-node-details-$materialLineId')),
    findsOneWidget,
  );
}

Future<void> _closeMaterialTableDetails(WidgetTester tester) async {
  await tester.tap(find.text('关闭').last);
  await tester.pumpAndSettle();
}

Future<void> _openAggregateMaterialDetails(WidgetTester tester) async {
  await _openMaterialTableDetails(tester, 'agg-path-1');
}

Future<void> _chooseMaterialRoute(
  WidgetTester tester,
  String lineId,
  String label, {
  bool confirm = true,
}) async {
  await _materialTableRowVisible(tester, lineId);
  final dropdown = find.byKey(ValueKey('material-route-dropdown-$lineId'));
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
  if (confirm) {
    await tester.tap(find.byKey(const Key('material-analysis-create-routes')));
    await tester.pumpAndSettle();
  }
}

Future<void> _chooseRoute(WidgetTester tester, String label) =>
    _chooseMaterialRoute(tester, 'material-path-1', label);

/// 点主表列头（进度 / 供应方式）打开筛选下拉，选一个桶（文案「标签 (计数)」）。
Future<void> _selectMaterialHeaderFilter(
  WidgetTester tester,
  String columnLabel,
  String bucketText,
) async {
  // 宽屏联动模式下列头随表体滚动：ensureVisible(row) 会把列头顶出视口（offstage，
  // 默认 finder 跳过），所以不跳过 offstage、先把列头滚回来再点。
  final header = find.text(columnLabel, skipOffstage: false).first;
  await tester.ensureVisible(header);
  await tester.pumpAndSettle();
  await tester.tap(header, warnIfMissed: false);
  await tester.pumpAndSettle();
  final bucket = find.text(bucketText).last;
  await tester.ensureVisible(bucket);
  await tester.tap(bucket);
  await tester.pumpAndSettle();
}

Future<void> _selectAllMaterialRoutes(WidgetTester tester) async {
  await _resetPageScrolls(tester);
  // 「全选筛选结果」已下线：改为逐页勾选表头复选框（选择全局累计）。
  while (true) {
    final header = find.descendant(
      of: find.byKey(const Key('material-analysis-material-table-region')),
      matching: find.byWidgetPredicate((w) => w is Checkbox && w.tristate),
    );
    await tester.ensureVisible(header);
    await tester.pumpAndSettle();
    await tester.tap(header);
    await tester.pumpAndSettle();
    final next = find.widgetWithText(TextButton, '下一页');
    final canGo =
        next.evaluate().isNotEmpty &&
        tester.widget<TextButton>(next).onPressed != null;
    if (!canGo) break;
    await tester.tap(next);
    await tester.pumpAndSettle();
  }
}

Future<void> _createDefaultRoutes(WidgetTester tester) async {
  await _selectAllMaterialRoutes(tester);
  await tester.tap(find.byKey(const Key('material-analysis-create-routes')));
  await tester.pumpAndSettle();
}

// ===== 2026-09-04 分桶改版：主页面入口条 + 全屏分桶详情页的通用操作 =====

/// 点主页面顶部入口卡进入分桶详情页。
///
/// [bucket] is buy / subcontract / workshop; stateFilter selects issue status.
Future<void> _openBucketDetail(
  WidgetTester tester,
  String bucket, {
  String? stateFilter,
}) async {
  final entry = find.byKey(Key('material-analysis-entry-$bucket'));
  if (entry.evaluate().isEmpty) {
    // 联动滚动后头区被收起、入口卡被惰性销毁：先滚回顶部再定位。
    await _resetPageScrolls(tester);
  }
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
  if (stateFilter != null) {
    final target = find.descendant(
      of: find.byKey(const Key('material-analysis-task-state')),
      matching: find.textContaining('$stateFilter ('),
    );
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }
}

/// 从分桶详情页返回宿主页（不发起批量动作）。
Future<void> _closeBucketDetail(WidgetTester tester) async {
  await tester.tap(find.byTooltip('返回').last);
  await tester.pumpAndSettle();
}

/// 断言主页面入口卡上的分桶计数（入口徽标与详情页行数同源）。
/// 须在联动头区可见时调用（被滚动收起后入口卡不在树中；先 _resetPageScrolls）。
void _expectBucketCount(WidgetTester tester, String bucket, int count) {
  expect(
    find.descendant(
      of: find.byKey(Key('material-analysis-entry-$bucket')),
      matching: find.text('$count'),
    ),
    findsOneWidget,
  );
}

/// 分桶表格的表头三态全选框。MasterDataTableView 与 UtenEditableGrid 的
/// 表头全选框都是 tristate，行勾选框都不是——用 tristate 唯一定位表头。
Finder _bucketHeaderCheckbox() =>
    find.byWidgetPredicate((widget) => widget is Checkbox && widget.tristate);

/// 详情页里的竖向滚动视图（横向滚动条在树序上更靠前，需按方向过滤）。
Finder _verticalScrollable() => find.byWidgetPredicate(
  (widget) =>
      widget is Scrollable && widget.axisDirection == AxisDirection.down,
);

/// 滚动桶详情页到目标行可见（懒构建列表里未出现的行先滚动出再定位）。
Future<void> _scrollBucketRowVisible(
  WidgetTester tester,
  String goodsName,
) async {
  final rowText = find.text(goodsName);
  if (rowText.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      rowText,
      200,
      scrollable: _verticalScrollable().first,
    );
    await tester.pumpAndSettle();
    return;
  }
  await tester.ensureVisible(rowText.first);
  await tester.pumpAndSettle();
}

/// 滚动到目标行并点选行首勾选框（按货品名文本定位表格行）。
Future<void> _tapBucketRowCheckbox(
  WidgetTester tester,
  String goodsName,
) async {
  await _scrollBucketRowVisible(tester, goodsName);
  final row = _frozenRowOf(goodsName);
  final checkbox = find
      .descendant(of: row, matching: find.byType(Checkbox))
      .first;
  await tester.ensureVisible(checkbox);
  await tester.pumpAndSettle();
  await tester.tap(checkbox);
  await tester.pump();
}

/// 读取某行行首勾选框的当前值（先按货品名定位行）。
bool _bucketRowCheckboxValue(WidgetTester tester, String goodsName) {
  final row = _frozenRowOf(goodsName);
  return tester
      .widget<Checkbox>(
        find.descendant(of: row, matching: find.byType(Checkbox)).first,
      )
      .value!;
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
  List<Map<String, dynamic>> warehouseEntries = const [
    {'id': 'warehouse-1', 'name': '主仓'},
  ],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final requests = <RequestOptions>[];
  final api = _api(
    requests,
    allowedActions,
    warehouseEntries: warehouseEntries,
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
  final GoRouter? router = withPlanRoute
      ? GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => page),
            if (withPlanRoute)
              GoRoute(
                path: '/production/plans/:id',
                builder: (_, state) =>
                    Scaffold(body: Text('已打开计划 ${state.pathParameters['id']}')),
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
        employeeRepositoryProvider.overrideWithValue(
          DioEmployeeRepository(api),
        ),
        departmentRepositoryProvider.overrideWithValue(
          _FakeDepartmentRepository(),
        ),
        departmentPickerTreeProvider.overrideWith(
          (ref) async => const <DepartmentNode>[],
        ),
        productionWorkshopTreeProvider.overrideWith(
          (ref) async => _productionWorkshops(),
        ),
        materialAnalysisWarehousePrefsProvider.overrideWith(
          _TestMaterialAnalysisWarehousePrefsNotifier.new,
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: router == null
          ? MaterialApp(
              theme: theme,
              builder: mediaBuilder,
              home: page,
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            )
          : MaterialApp.router(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
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

/// 可安排桶车间/负责人编辑依赖组织树（`_workshopTreeOrNull` 直读部门仓库）。
/// 提供生产部直属「装配一车间」，车间经理=worker-1 王负责人（与 /org/employees
/// 桩一致），负责人随车间自动带出。
class _FakeDepartmentRepository implements DepartmentRepository {
  @override
  Future<List<DepartmentNode>> tree() async => [
    DepartmentNode(
      id: 'production',
      code: 'DEPT_PROD',
      name: '生产部',
      level: '一级部门',
      children: [
        DepartmentNode(
          id: 'workshop-1',
          code: 'WS_ASSEMBLY',
          name: '装配一车间',
          level: '二级班组',
          parentId: 'production',
          managerId: 'worker-1',
          managerName: '王负责人',
          children: const [],
        ),
      ],
    ),
  ];

  @override
  Future<DepartmentInfo> detail(String id) => throw UnimplementedError();

  @override
  Future<WorkforceOverview> workforceOverview(String id) =>
      throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 点可安排桶计划行的「生产车间」格（空态「点击选择」），在右侧滑窗里点选
/// 车间（单选点行即选定返回）；负责人由车间经理自动带出（黄标提醒核对）。
Future<void> _pickBucketRowWorkshop(
  WidgetTester tester,
  Finder row,
  String workshopName,
) async {
  final cell = find.descendant(of: row, matching: find.text('点击选择')).first;
  await tester.ensureVisible(cell);
  await tester.pumpAndSettle();
  await tester.tap(cell);
  await tester.pumpAndSettle();
  final option = find.text(workshopName).last;
  await tester.tap(option);
  await tester.pumpAndSettle();
}

class _TestMaterialAnalysisWarehousePrefsNotifier
    extends MaterialAnalysisWarehousePrefsNotifier {
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
  required List<Map<String, dynamic>> warehouseEntries,
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
              '/master/warehouses/dict' => warehouseEntries,
              // 路线「学习预填」（2026-09 新增）：默认无记忆，避免页面加载时
              // 因该路径未注册而抛错/多打异常请求。
              '/production/material-analyses/last-routes' =>
                <String, dynamic>{},
              // 可安排桶详情页「负责人」选择的员工候选（PagedResult 契约）。
              '/org/employees' => {
                'items': [
                  {
                    'id': 'worker-1',
                    'code': 'E-001',
                    'fullName': '王负责人',
                    'departmentId': 'workshop-1',
                    'departmentName': '装配一车间',
                  },
                ],
                'page': 1,
                'size': 30,
                'total': 1,
                'totalPages': 1,
              },
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

/// 大分析 fixture（性能看门狗用）：[productCount] 个不可安排产品，每个带
/// 1 个已确认 MAKE 的缺料候选（下层未齐）+ 1 个下层缺料子件 —— 物料数 =
/// 2×产品数，候选判定会同时吃「有子层」「直接子层缺料」两条查询路径。
Map<String, dynamic> _bigWaitingAnalysisJson({int productCount = 1500}) {
  final products = <Map<String, dynamic>>[];
  final materials = <Map<String, dynamic>>[];
  for (var i = 0; i < productCount; i++) {
    final lineId = 'big-product-$i';
    products.add({
      'analysisLineId': lineId,
      'sourceType': 'STOCK',
      'goodsCode': 'BIG-$i',
      'goodsName': '大分析产品$i',
      'requestedQty': 10,
      'remainingQty': 10,
      'readyNowQty': 0,
      'canSchedule': false,
      'maxSchedulableQty': 0,
      'readyByDateQty': 0,
      'readinessRatio': 0,
    });
    // 同款 BOM 的多个订单分析项会复用 nodeKey；唯一身份是
    // (analysisLineId, nodeKey)。fixture 刻意复用节点键，防止索引只按
    // nodeKey 建桶后每个候选再扫描全部订单行，悄悄退化回 O(产品²)。
    const candidateNode = 'shared-candidate-node';
    materials.add({
      'materialLineId': 'big-cand-$i',
      'analysisLineId': lineId,
      'nodeKey': candidateNode,
      'actionGroupKey': 'big-cand-action-$i',
      'materialKey': 'BIG-C-$i||unit-1',
      'goodsId': 'big-cand-goods-$i',
      'goodsCode': 'BIG-C-$i',
      'goodsName': '待制组件$i',
      'unitName': '个',
      'level': 1,
      'path': ['大分析产品$i', '待制组件$i'],
      'requiredQty': 10,
      'availableQty': 0,
      'allocatedAvailableQty': 0,
      'shortageQty': 10,
      'sourceSuggestion': 'MAKE',
      'sourceConfirmed': 'MAKE',
      'routeConfirmed': true,
      'controlStage': 'ASSEMBLY',
      'hardGate': true,
      'actionable': true,
      'lowerLevelPending': true,
    });
    materials.add({
      'materialLineId': 'big-child-$i',
      'analysisLineId': lineId,
      'nodeKey': 'shared-child-node',
      'parentNodeKey': candidateNode,
      'actionGroupKey': 'big-child-action-$i',
      'materialKey': 'BIG-L-$i||unit-1',
      'goodsId': 'big-child-goods-$i',
      'goodsCode': 'BIG-L-$i',
      'goodsName': '下层料$i',
      'unitName': '个',
      'level': 2,
      'path': ['大分析产品$i', '待制组件$i', '下层料$i'],
      'requiredQty': 20,
      'availableQty': 0,
      'allocatedAvailableQty': 0,
      'shortageQty': 20,
      'sourceSuggestion': 'BUY',
      'routeConfirmed': false,
      'controlStage': 'FINISH',
      'hardGate': true,
      'actionable': true,
    });
  }
  return {
    'analysisId': 'analysis-big-1',
    'status': 'ANALYZED',
    'version': 3,
    'fingerprint': 'b' * 64,
    'warehouseId': 'warehouse-1',
    'warehouseIds': const ['warehouse-1'],
    'analyzedAt': '2026-08-08T10:00:00Z',
    'allowedActions': const ['NOTIFY_SUPPLY', 'GENERATE_PLAN', 'PLAN_PREVIEW'],
    'products': products,
    'flatMaterials': materials,
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
  'warehouseIds': const ['warehouse-1'],
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
      'canSchedule': true,
      'maxSchedulableQty': 4,
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
      'canSchedule': true,
      'maxSchedulableQty': 2,
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
      'mainWarehousePublicAvailableQty': 7,
      'mainWarehouseOpenSafetySupplyQty': 0,
      'mainWarehouseSafetyReplenishmentGapQty': 0,
      'warehouseBreakdown': [
        {
          'warehouseId': 'warehouse-1',
          'warehouseCode': 'WH-01',
          'warehouseName': '主仓',
          'onHandQty': 7,
          'reservedQty': 0,
          'availableQty': 7,
          'ownPeggedQty': 0,
          'publicAvailableQty': 7,
          'openSafetySupplyQty': 0,
          'safetyReplenishmentGapQty': 0,
        },
      ],
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
      ..['mainWarehousePublicAvailableQty'] = 2
      ..['mainWarehouseOpenSafetySupplyQty'] = 2
      ..['mainWarehouseSafetyReplenishmentGapQty'] = 6
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
  String route = 'BUY',
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
        'sourceSuggestion': route,
        'sourceConfirmed': index <= confirmedCount ? route : null,
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

/// 计划向导类用例的公共底料：已通知 MAKE 的节点 + 可安排的子件产品（
/// make-child-ready-1），make-path-2 关闭可执行性聚焦单条。物料表行和
/// 可安排桶的计划入口复用同一业务链路。
Map<String, dynamic> _planReadyChildAnalysisJson({double readyNowQty = 4}) {
  final json = _makeReadyChildAnalysisJson()
    ..['allowedActions'] = const [
      'NOTIFY_SUPPLY',
      'GENERATE_PLAN',
      'PLAN_PREVIEW',
    ];
  (json['flatMaterials']! as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .singleWhere((material) => material['materialLineId'] == 'make-path-2')
      .addAll(const {'actionable': false, 'shortageQty': 0});
  final child =
      (json['products']! as List<dynamic>).last as Map<String, dynamic>;
  child
    ..['readyNowQty'] = readyNowQty
    ..['canSchedule'] = readyNowQty > 0
    ..['maxSchedulableQty'] = readyNowQty;
  return json;
}

Map<String, dynamic> _pendingMakeCandidateAnalysisJson({
  bool lowerLevelPending = true,
  bool includeRealChild = false,
  bool actionable = true,
  bool includeMixedReadyCandidate = false,
  String parentRoute = 'MAKE',
  String childSourceType = 'MAKE_COMPONENT',
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
      route: parentRoute,
      controlStage: 'ASSEMBLY',
    ),
    'lowerLevelPending': lowerLevelPending,
    'actionable': actionable,
    if (includeRealChild)
      'notifiedTargets': [
        {
          'target': parentRoute,
          'documentType': parentRoute == 'SUBCONTRACT'
              ? 'SUBCONTRACT_MAKE_TASK'
              : 'PREPLAN_MAKE_TASK',
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
      'sourceType': childSourceType,
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
    ..['mainWarehousePublicAvailableQty'] = inventoryCovered ? 10 : 0
    ..['mainWarehouseOpenSafetySupplyQty'] = 0
    ..['mainWarehouseSafetyReplenishmentGapQty'] = 0
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
    ..['canSchedule'] = false
    ..['maxSchedulableQty'] = 0
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
  'exactPeggedQty': 0,
  'availableQty': 2,
  'shortageQty': 8,
  'demandSupplyGapQty': 8,
  'additionalSupplyRecommendedQty': 8,
  'selectedWarehousesAvailableQty': 2,
  'selectedOtherWarehouseTransferableQty': 0,
  'publicSurplusApprovedInboundQty': 0,
  'publicSurplusRemainingQty': 0,
  'sharedFutureClaimedQty': 0,
  'sharedFutureSupplyRefs': const <Map<String, dynamic>>[],
  'mainWarehousePublicAvailableQty': 0,
  'mainWarehouseOpenSafetySupplyQty': 0,
  'mainWarehouseSafetyReplenishmentGapQty': 0,
  'warehouseBreakdown': const [
    {
      'warehouseId': 'warehouse-1',
      'warehouseCode': 'WH-01',
      'warehouseName': '主仓',
      'onHandQty': 2,
      'reservedQty': 0,
      'availableQty': 2,
      'ownPeggedQty': 0,
      'publicAvailableQty': 0,
      'openSafetySupplyQty': 0,
      'safetyReplenishmentGapQty': 0,
    },
  ],
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
  'exactPeggedQty': 0,
  'availableQty': 3,
  'inboundQty': 2,
  'shortageQty': 11,
  'demandSupplyGapQty': 13,
  'additionalSupplyRecommendedQty': 11,
  'selectedWarehousesAvailableQty': 3,
  'selectedOtherWarehouseTransferableQty': 0,
  'publicSurplusApprovedInboundQty': 0,
  'publicSurplusRemainingQty': 0,
  'sharedFutureClaimedQty': 0,
  'sharedFutureSupplyRefs': const <Map<String, dynamic>>[],
  'mainWarehousePublicAvailableQty': 0,
  'mainWarehouseOpenSafetySupplyQty': 0,
  'mainWarehouseSafetyReplenishmentGapQty': 0,
  'warehouseBreakdown': const [
    {
      'warehouseId': 'warehouse-1',
      'warehouseCode': 'WH-01',
      'warehouseName': '主仓',
      'onHandQty': 3,
      'reservedQty': 0,
      'availableQty': 3,
      'ownPeggedQty': 0,
      'publicAvailableQty': 0,
      'openSafetySupplyQty': 0,
      'safetyReplenishmentGapQty': 0,
    },
  ],
  'sourceSuggestion': 'BUY',
  'sourceConfirmed': routeConfirmed ? 'MAKE' : null,
  'routeConfirmed': routeConfirmed,
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

/// 点「提交采购/委外」按钮后弹总结确认对话框（品种数+合计；数量编辑
/// 已前移到表格行内）；测试默认全量提交，直接点确认。
Future<void> _confirmSupplyQuantityDialog(WidgetTester tester) async {
  final confirm = find.byKey(const Key('supply-submit-confirm'));
  await tester.ensureVisible(confirm);
  await tester.pumpAndSettle();
  await tester.tap(confirm);
  await tester.pumpAndSettle();
}

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

/// 把表格的横向滚动归零。
///
/// `tester.ensureVisible` 会把目标对齐到视口**左缘**，而首列勾选框是冻结列
/// （UtenFrozenLeadingColumn：横滚后钉在视口左缘），对齐过去的内容正好躲进它底下
/// ——这是 sticky 列的固有行为（内容从冻结列下面滚过），真机上用户往左拖一点就看见了。
/// 测试里点这类首列控件前先把横滚归零。
Future<void> _resetTableHScroll(WidgetTester tester) async {
  for (final state in tester.stateList<ScrollableState>(
    find.byType(Scrollable),
  )) {
    final position = state.position;
    if (position.axis == Axis.horizontal &&
        position.hasPixels &&
        position.pixels != 0) {
      position.jumpTo(0);
    }
  }
  await tester.pump();
}
