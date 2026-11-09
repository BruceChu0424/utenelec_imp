import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/filter_segment_tap.dart';
import '../../support/page_resume_test_bridge.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/quality/models/production_fqc_inspection.dart';
import 'package:uten_imp/features/quality/pages/production_fqc_handling_page.dart';
import 'package:uten_imp/features/quality/pages/production_fqc_inspections_page.dart';
import 'package:uten_imp/features/quality/pages/quality_batch_approval_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/task_form_draft_recovery_notice.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/search/keyword_search.dart';

const _inspectionId = '10000000-0000-0000-0000-000000000001';
const _reportNo = 'RB202608280001';
final _fqcPermissions = StateProvider<Set<String>>((ref) => {});

Future<void> _pumpPage(
  WidgetTester tester, {
  required _FqcApi api,
  required Set<String> permissions,
  ProductionFqcInspection? handlingResult,
}) async {
  await tester.binding.setSurfaceSize(const Size(375, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  // 批量审批页依赖 shared_preferences（页面偏好缓存）。
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: RouteName.productionFqcInspections,
    routes: [
      GoRoute(
        path: RouteName.productionFqcInspections,
        builder: (_, _) => const ProductionFqcInspectionsPage(),
      ),
      GoRoute(
        path: '${RouteName.productionFqcInspectionHandlingBase}/:inspectionId',
        builder: (context, state) => handlingResult == null
            ? ProductionFqcInspectionPage(
                inspectionId: state.pathParameters['inspectionId']!,
                extra: state.extra,
              )
            : Scaffold(
                body: TextButton(
                  onPressed: () {
                    api.decided = true;
                    context.pop(handlingResult);
                  },
                  child: const Text('返回部分已决定结果'),
                ),
              ),
      ),
      GoRoute(
        path: RouteName.warehouseInspectionBatchApproval,
        builder: (_, state) => QualityBatchApprovalPage(
          selection: state.extra is QualityBatchApprovalSelection
              ? state.extra! as QualityBatchApprovalSelection
              : const QualityBatchApprovalSelection(),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        _fqcPermissions.overrideWith((ref) => permissions),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_fqcPermissions),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      // 带路由壳：2026-09-12 起双击进 FQC 办理页、批量审批进汇总页（都不再弹窗）。
      child: PageResumeTestBridge(
        router: router,
        child: MaterialApp.router(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _drainAsyncWork(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

MasterDataTableView<ProductionFqcInspection> _taskTable(WidgetTester tester) =>
    tester.widget<MasterDataTableView<ProductionFqcInspection>>(
      find.byKey(const Key('production-fqc-inspection-table')),
    );

Future<void> _doubleTapRow(WidgetTester tester, String reportNo) async {
  final row = find.text(reportNo);
  await tester.tap(row);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(row);
  await tester.pumpAndSettle();
}

void main() {
  for (final defect in ['duplicate identity', 'scope drift']) {
    testWidgets(
      'complete FQC queue rejects $defect and retries the full scope',
      (tester) async {
        final api = _FqcApi(totalPages: 2)
          ..duplicateSecondPage = defect == 'duplicate identity'
          ..changedReadScope = defect == 'scope drift';
        await _pumpPage(
          tester,
          api: api,
          permissions: const {
            Perm.productionQualityInspectionView,
            Perm.productionQualityInspectionApprove,
          },
        );
        // 2026-11-08 逐批读取：校验通过的首批 40 行先进 provisional 展示；
        // 第二批身份/范围漂移后整个会话退休，半截列表不得当作当前结果展示，
        // 失败改为在保留值上方内联提示（error 仅在无值时下推到表格）。
        final partial = _taskTable(tester).items;
        expect(partial, isNotEmpty);
        expect(readWindowBindingOf(partial)!.isCurrent, isFalse);
        expect(find.textContaining('刷新失败：'), findsOneWidget);
        expect(_taskTable(tester).selectedIds, isEmpty);
        api.duplicateSecondPage = false;
        api.changedReadScope = false;
        _taskTable(tester).onRetry!();
        await tester.pumpAndSettle();
        expect(_taskTable(tester).items, hasLength(80));
        expect(
          _taskTable(tester).items.map((item) => item.id).toSet(),
          hasLength(80),
        );
        expect(_taskTable(tester).error, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'status header queries one exact state inside the current queue',
    (tester) async {
      final api = _FqcApi();
      await _pumpPage(
        tester,
        api: api,
        permissions: {Perm.productionQualityInspectionView},
      );
      await tester.tap(find.text('状态'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('部分已决定'));
      await tester.pumpAndSettle();
      expect(api.listQueries.last['status'], 'PARTIAL');
      expect(api.listQueries.last['page'], 1);
      expect(_taskTable(tester).items.single.status, 'PARTIAL');
      expect(_taskTable(tester).filters['status'], 'PARTIAL');
      _taskTable(tester).onFilterChanged('search.remainingQty', '>=1');
      await tester.pumpAndSettle();
      expect(api.listQueries.last['search.remainingQty'], '>=1');
      expect(api.listQueries.last['status'], 'PARTIAL');
      _taskTable(tester).onSortChange!('remainingQty', false);
      await tester.pumpAndSettle();
      expect(api.listQueries.last['sort'], 'remainingQty');
      expect(api.listQueries.last['order'], 'desc');
      expect(api.listQueries.last['page'], 1);
      await _doubleTapRow(tester, _reportNo);
      expect(find.byType(ProductionFqcInspectionPage), findsOneWidget);
      expect(api.decisionBody, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('FQC 授权后读取审核池，撤权立即隐藏其他来源并重新读取本人范围', (tester) async {
    final api = _FqcApi();
    await _pumpPage(
      tester,
      api: api,
      permissions: {Perm.productionQualityInspectionView},
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProductionFqcInspectionsPage)),
    );
    expect(_taskTable(tester).selectable, isFalse);
    final reads = api.listQueries.length;
    expect(find.text('FQC-其他来源'), findsNothing);
    api.showPoolRows = true;
    container.read(_fqcPermissions.notifier).state = {
      Perm.productionQualityInspectionView,
      Perm.productionQualityInspectionApprove,
    };
    await tester.pumpAndSettle();
    expect(_taskTable(tester).selectable, isTrue);
    expect(api.capabilityCalls, 1);
    expect(api.listQueries.length, reads + 1);
    expect(find.text('FQC-其他来源'), findsOneWidget);
    final ownerRead = Completer<void>();
    api.showPoolRows = false;
    api.listReadGate = ownerRead;
    container.read(_fqcPermissions.notifier).state = {
      Perm.productionQualityInspectionView,
    };
    await tester.pump();
    expect(find.text('FQC-其他来源'), findsNothing);
    expect(_taskTable(tester).selectable, isFalse);
    ownerRead.complete();
    await tester.pumpAndSettle();
    expect(_taskTable(tester).selectable, isFalse);
    expect(find.text(_reportNo), findsOneWidget);
    expect(find.text('FQC-其他来源'), findsNothing);
    expect(api.listQueries.length, reads + 2);
    expect(api.capabilityCalls, 1);
    expect(api.decisionBody, isNull);
    expect(api.batchBody, isNull);
  });

  testWidgets('FQC单任务权限变化只刷新办理能力，保留已填数量和原幂等键', (tester) async {
    final api = _FqcApi();
    await _pumpPage(
      tester,
      api: api,
      permissions: {Perm.productionQualityInspectionView},
    );
    await _doubleTapRow(tester, _reportNo);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProductionFqcInspectionPage)),
    );
    expect(find.byKey(const Key('fqc-inspection-submit-report')), findsNothing);
    final capability = Completer<Map<String, dynamic>>();
    api.capabilityResponse = capability;
    container.read(_fqcPermissions.notifier).state = {
      Perm.productionQualityInspectionView,
      Perm.productionQualityInspectionApprove,
    };
    await tester.pump();
    expect(
      find.byKey(const Key('fqc-inspection-submit-report')),
      findsNothing,
      reason: 'approval waits for the fresh server capability',
    );
    capability.complete({'canDecide': true});
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('fqc-inspection-submit-report')),
      findsOneWidget,
    );
    FqcReportRow row() => tester
        .widget<MasterDataTableView<FqcReportRow>>(
          find.byKey(const Key('fqc-inspection-decision-table')),
        )
        .items
        .single;
    row().pass.text = '1.';
    row().fail.text = '2';
    final key = row().idempotencyKey;
    final detailReads = api.detailCalls;
    container.read(_fqcPermissions.notifier).state = {
      Perm.productionQualityInspectionView,
    };
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fqc-inspection-submit-report')), findsNothing);
    container.read(_fqcPermissions.notifier).state = {
      Perm.productionQualityInspectionView,
      Perm.productionQualityInspectionApprove,
    };
    await tester.pumpAndSettle();
    expect(row().pass.text, '1.');
    expect(row().fail.text, '2');
    expect(row().idempotencyKey, key);
    expect(api.detailCalls, detailReads);
    expect(api.decisionBody, isNull);
    // Reading authority remains a sticky boundary even though the narrower
    // approval permission can change without destroying unfinished quantities.
    container.read(_fqcPermissions.notifier).state = {};
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('fqc-inspection-decision-table')),
      findsNothing,
    );
    expect(find.byKey(const Key('fqc-inspection-submit-report')), findsNothing);
    container.read(_fqcPermissions.notifier).state = {
      Perm.productionQualityInspectionView,
      Perm.productionQualityInspectionApprove,
    };
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('fqc-inspection-decision-table')),
      findsNothing,
      reason: 'restored grants cannot revive a retired read owner',
    );
  });

  for (final search in ['', '本色\tV51043']) {
    testWidgets('部分决定后刷新失败保留同查询，返回清空搜索时隔离旧查询 ($search)', (tester) async {
      final api = _FqcApi(failReloadAfterDecision: true);
      final partial = ProductionFqcInspection.fromJson({
        ...api._inspection,
        'passedQty': 1,
        'remainingQty': 9,
        'status': 'PARTIAL',
      });
      await _pumpPage(
        tester,
        api: api,
        permissions: const {Perm.productionQualityInspectionView},
        handlingResult: partial,
      );
      if (search.isNotEmpty) {
        await tester.enterText(find.byType(TextField).first, search);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
      }
      expect(_taskTable(tester).items.single.id, _inspectionId);
      expect(api.listQueries.last['keyword'], search.isEmpty ? null : search);
      await _doubleTapRow(tester, _reportNo);
      await tester.tap(find.text('返回部分已决定结果'));
      await tester.pumpAndSettle();
      if (search.isEmpty) {
        expect(_taskTable(tester).items.single.status, 'PARTIAL');
        expect(_taskTable(tester).items.single.remainingQty, 9);
      } else {
        expect(api.listQueries.last['keyword'], isNull);
        expect(
          _taskTable(tester).items,
          isEmpty,
          reason:
              'return clears page search, so its failed new query cannot display older filtered rows',
        );
        expect(_taskTable(tester).error, isNotNull);
      }
      expect(_taskTable(tester).currentPage, 1);
      expect(api.decisionBody, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'manual FQC refresh preserves raw report input and retry identity',
    (tester) async {
      final api = _FqcApi();
      await _pumpPage(
        tester,
        api: api,
        permissions: const {
          Perm.productionQualityInspectionView,
          Perm.productionQualityInspectionApprove,
        },
      );
      await _doubleTapRow(tester, _reportNo);
      FqcReportRow row() => tester
          .widget<MasterDataTableView<FqcReportRow>>(
            find.byKey(const Key('fqc-inspection-decision-table')),
          )
          .items
          .single;
      final before = row();
      before.pass.text = '1.';
      before.fail.text = '2';
      before.disposition = 'SCRAP';
      final key = before.idempotencyKey;
      final detailCalls = api.detailCalls;
      final moreActions = find
          .byKey(const Key('uten-app-bar-more-actions'))
          .hitTestable();
      expect(moreActions, findsOneWidget);
      await tester.tap(moreActions);
      await tester.pumpAndSettle();
      final refresh = find.byTooltip('刷新').hitTestable();
      expect(refresh, findsOneWidget);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(api.detailCalls, detailCalls + 1);
      expect(row().pass.text, '1.');
      expect(row().fail.text, '2');
      expect(row().disposition, 'SCRAP');
      expect(row().idempotencyKey, key);
      expect(api.decisionBody, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('375px table supports selection, detail, and PASS decision', (
    tester,
  ) async {
    final api = _FqcApi();
    await _pumpPage(
      tester,
      api: api,
      permissions: const {
        Perm.productionQualityInspectionView,
        Perm.productionQualityInspectionApprove,
      },
    );

    expect(find.text('生产成品质检'), findsOneWidget);
    expect(
      find.byKey(const Key('production-fqc-inspection-table')),
      findsOneWidget,
    );
    final initialTable = _taskTable(tester);
    expect(initialTable.selectable, isTrue);
    expect(initialTable.idOf!(initialTable.items.single), _inspectionId);
    expect(initialTable.selectedIds, isEmpty);
    expect(initialTable.batchActionsBuilder, isNotNull);
    expect(
      initialTable.columns.map((column) => column.key),
      containsAll(<String>{
        'status',
        'reportNo',
        'planNo',
        'goodsCode',
        'goodsName',
        'colorName',
        'reportedQty',
        'passedQty',
        'failedQty',
        'remainingQty',
        'authorizedInboundQty',
      }),
    );
    expect(find.text('已选 0 项'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(2));

    await tester.tap(find.text(_reportNo));
    await tester.pump();
    expect(_taskTable(tester).selectedIds, {_inspectionId});
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(
      find.byKey(const Key('production-fqc-detail-$_inspectionId')),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 400));

    await _doubleTapRow(tester, _reportNo);
    // 2026-09-12 弹窗改页：进入 FQC 单任务办理页（详情事实 + 决定表单）。
    expect(find.byKey(const Key('fqc-inspection-facts-table')), findsOneWidget);
    final submit = find.byKey(const Key('fqc-inspection-submit-report'));
    expect(submit, findsOneWidget);
    expect(find.text('合格数量'), findsOneWidget);

    await tester.tap(submit);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await _drainAsyncWork(tester);

    expect(api.decisionBody?['decision'], 'PASS');
    expect(api.decisionBody?['passQty'], 10);
    expect(api.decisionBody?['idempotencyKey'], startsWith('fqc-report-'));
    // 决定成功带结果返回：行已本地移除（不等刷新）。
    expect(find.text(_reportNo), findsNothing);
    expect(_taskTable(tester).items, isEmpty);
    expect(find.text('当前筛选下没有生产质检任务'), findsOneWidget);
    expect(api.listQueries.last['status'], 'ACTIVE');
    expect(api.listQueries.last['page'], 1);
    expect(tester.takeException(), isNull);
  });

  for (final scenario
      in <
        ({
          String name,
          Set<String> permissions,
          bool canDecide,
          int capabilityCalls,
        })
      >[
        (
          name: 'approve authority outside quality scope',
          permissions: const {
            Perm.productionQualityInspectionView,
            Perm.productionQualityInspectionApprove,
          },
          canDecide: false,
          // 列表 _load 查一次 + 办理页开页查一次。
          capabilityCalls: 2,
        ),
        (
          name: 'view-only authority',
          permissions: const {Perm.productionQualityInspectionView},
          canDecide: true,
          capabilityCalls: 0,
        ),
      ]) {
    testWidgets('${scenario.name} can open read-only detail', (tester) async {
      final api = _FqcApi(canDecide: scenario.canDecide);
      await _pumpPage(tester, api: api, permissions: scenario.permissions);

      expect(_taskTable(tester).selectable, isFalse);
      await _doubleTapRow(tester, _reportNo);
      // 办理页只读态：无决定表单，只有详情事实与证据。
      expect(
        find.byKey(const Key('fqc-inspection-facts-table')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('fqc-inspection-submit-report')),
        findsNothing,
      );
      expect(find.textContaining('当前为只读查看'), findsOneWidget);
      expect(api.capabilityCalls, scenario.capabilityCalls);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('successful decision stays locally resolved when reload fails', (
    tester,
  ) async {
    final api = _FqcApi(failReloadAfterDecision: true);
    await _pumpPage(
      tester,
      api: api,
      permissions: const {
        Perm.productionQualityInspectionView,
        Perm.productionQualityInspectionApprove,
      },
    );
    await _doubleTapRow(tester, _reportNo);
    await tester.tap(find.byKey(const Key('fqc-inspection-submit-report')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await _drainAsyncWork(tester);

    expect(find.text(_reportNo), findsNothing);
    expect(_taskTable(tester).items, isEmpty);
    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(api.listQueries, hasLength(2));
    expect(api.listQueries.last['status'], 'ACTIVE');
    expect(api.listQueries.last['page'], 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected active tasks go to batch approval page (pass-all)', (
    tester,
  ) async {
    final api = _FqcApi();
    await _pumpPage(
      tester,
      api: api,
      permissions: const {
        Perm.productionQualityInspectionView,
        Perm.productionQualityInspectionApprove,
      },
    );

    await tester.tap(find.text(_reportNo));
    await tester.pump();
    expect(_taskTable(tester).selectedIds, {_inspectionId});
    // 2026-09-12 与待检处置统一：右下角「批量审批」进汇总页（默认全勾=全部合格）。
    final action = find.byKey(const Key('production-fqc-batch-approval'));
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('batch-approval-submit-report')),
      findsOneWidget,
    );
    expect(find.textContaining('勾选即全部合格'), findsOneWidget);
    await tester.tap(find.byKey(const Key('batch-approval-submit-report')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await _drainAsyncWork(tester);

    expect(api.batchBody?['inspectionIds'], [_inspectionId]);
    expect(api.batchBody?['idempotencyKey'], startsWith('fqc-batch-approval-'));
    expect(find.text(_reportNo), findsNothing);
    expect(_taskTable(tester).items, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'batch approval shows storage location for pre-stocked FQC rows',
    (tester) async {
      final api = _FqcApi(includeStocked: true);
      await _pumpPage(
        tester,
        api: api,
        permissions: const {
          Perm.productionQualityInspectionView,
          Perm.productionQualityInspectionApprove,
        },
      );

      await tester.tap(find.text('RB-STOCKED'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('production-fqc-batch-approval')));
      await tester.pumpAndSettle();

      // 2026-09-18 用户口径：批量页也要逐行看到储放位置；已上架行红字
      //「已入库 · 仓 / 库位」覆盖登记库位，与 FQC 办理页同口径。
      // 2026-10-02 合一表：单张 batch-approval-unified-table（无 legacy 分表）。
      expect(
        find.byKey(const Key('batch-approval-unified-table')),
        findsOneWidget,
      );
      expect(find.text('储放位置'), findsOneWidget);
      expect(find.text('已入库 · 成品一仓 / B-02'), findsOneWidget);
      expect(find.text('C-03'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'FQC queue completes 80 rows at 375px and scrolls without reads',
    (tester) async {
      final api = _FqcApi(totalPages: 2, pageSpecificRows: true);
      await _pumpPage(
        tester,
        api: api,
        permissions: const {
          Perm.productionQualityInspectionView,
          Perm.productionQualityInspectionApprove,
        },
      );

      expect(_taskTable(tester).currentPage, 1);
      expect(_taskTable(tester).totalPages, 1);
      expect(_taskTable(tester).items, hasLength(80));
      expect(api.listQueries.map((query) => query['page']), [1, 2]);
      // 2026-11-08 阶梯完整读取首批 size=50；该 fake 固定 40 行/页，
      // 读取器采纳服务端页大小后续批固定 40。
      expect(api.listQueries.map((query) => query['size']), [50, 40]);
      expect(
        find.byKey(const ValueKey('master-table-page-next')),
        findsNothing,
      );
      final rows = _taskTable(tester).items;
      final reads = api.listQueries.length;
      final table = find.byKey(const Key('production-fqc-inspection-table'));
      await tester.dragUntilVisible(
        find.text('FQC-PAGE-2-ROW-40'),
        table,
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      expect(find.text('FQC-PAGE-2-ROW-40').hitTestable(), findsOneWidget);
      await tester.dragUntilVisible(
        find.text('FQC-PAGE-1-ROW-1'),
        table,
        const Offset(0, 400),
      );
      await tester.pumpAndSettle();
      expect(find.text('FQC-PAGE-1-ROW-1').hitTestable(), findsOneWidget);
      expect(api.listQueries, hasLength(reads));
      expect(_taskTable(tester).items, same(rows));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'status segments retire the complete scope and clear controlled selection',
    (tester) async {
      final api = _FqcApi(totalPages: 2);
      await _pumpPage(
        tester,
        api: api,
        permissions: const {
          Perm.productionQualityInspectionView,
          Perm.productionQualityInspectionApprove,
        },
      );

      await tester.tap(find.text(_reportNo));
      await tester.pump();
      expect(_taskTable(tester).selectedIds, {_inspectionId});

      final beforeHistory = api.listQueries.length;
      await selectFilterSegment(tester, '历史单据');
      await tester.pumpAndSettle();
      final historyQueries = api.listQueries.skip(beforeHistory).toList();
      expect(historyQueries.first['status'], 'HISTORY');
      expect(historyQueries.first['page'], 1);
      expect(
        historyQueries.every((query) => query['status'] == 'HISTORY'),
        isTrue,
      );
      expect(find.byType(TaskDraftRecoveryNotice), findsNothing);
      expect(_taskTable(tester).currentPage, 1);
      expect(_taskTable(tester).selectedIds, isEmpty);
      expect(_taskTable(tester).selectable, isFalse);
      expect(find.text('RB-RESOLVED'), findsOneWidget);

      expect(find.text('RB-CANCELLED'), findsOneWidget);

      final beforeActive = api.listQueries.length;
      await selectFilterSegment(tester, '待处理');
      await tester.pumpAndSettle();
      final activeQueries = api.listQueries.skip(beforeActive).toList();
      expect(activeQueries.first['status'], 'ACTIVE');
      expect(activeQueries.first['page'], 1);
      expect(
        activeQueries.every((query) => query['status'] == 'ACTIVE'),
        isTrue,
      );
      expect(_taskTable(tester).currentPage, 1);
      expect(find.text('RB-RESOLVED'), findsNothing);
      expect(find.text('RB-CANCELLED'), findsNothing);
      expect(find.byType(TaskDraftRecoveryNotice), findsOneWidget);
    },
  );

  testWidgets(
    'search uses the built-in 300ms debounce and replaces the complete scope',
    (tester) async {
      final api = _FqcApi(totalPages: 2);
      await _pumpPage(
        tester,
        api: api,
        permissions: const {
          Perm.productionQualityInspectionView,
          Perm.productionQualityInspectionApprove,
        },
      );

      await tester.tap(find.text(_reportNo));
      await tester.pump();
      expect(_taskTable(tester).selectedIds, {_inspectionId});

      final listCallsBeforeSearch = api.listQueries.length;
      await tester.enterText(find.byType(TextField).first, 'V51043');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 299));
      expect(api.listQueries, hasLength(listCallsBeforeSearch));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();

      final searchQueries = api.listQueries
          .skip(listCallsBeforeSearch)
          .toList();
      expect(searchQueries.map((query) => query['page']), [1, 2]);
      // 首批 50 起步，fake 固定 40 行/页 → 续批采纳服务端页大小 40。
      expect(searchQueries.map((query) => query['size']), [50, 40]);
      expect(searchQueries.first['keyword'], 'V51043');
      expect(searchQueries.first['page'], 1);
      expect(
        searchQueries.where((query) => query['page'] == 1),
        hasLength(1),
        reason: 'one debounced complete read starts at the first bounded batch',
      );
      expect(
        searchQueries.every((query) => query['keyword'] == 'V51043'),
        isTrue,
      );
      expect(_taskTable(tester).currentPage, 1);
      expect(_taskTable(tester).selectedIds, isEmpty);
      expect(find.text(_reportNo), findsOneWidget);
    },
  );
}

class _FqcApi extends ApiClient {
  _FqcApi({
    this.canDecide = true,
    this.failReloadAfterDecision = false,
    this.totalPages = 1,
    this.includeStocked = false,
    this.pageSpecificRows = false,
  }) : super(Dio());

  Map<String, dynamic>? decisionBody;
  Map<String, dynamic>? batchBody;
  final bool canDecide;
  Completer<Map<String, dynamic>>? capabilityResponse;
  final bool failReloadAfterDecision;
  final int totalPages;
  final bool pageSpecificRows;
  bool duplicateSecondPage = false;
  bool changedReadScope = false;
  bool showPoolRows = false;
  Completer<void>? listReadGate;

  /// 额外给待检队列塞一行「先入库后检」的成品（带登记库位与已上架位置）。
  final bool includeStocked;
  bool decided = false;
  int requestedPage = 1;
  int capabilityCalls = 0;
  int detailCalls = 0;
  final List<Map<String, dynamic>> listQueries = [];

  Map<String, dynamic> get _inspection => const {
    'id': '10000000-0000-0000-0000-000000000001',
    'sourceReportId': '10000000-0000-0000-0000-000000000002',
    'sourceReportItemId': '10000000-0000-0000-0000-000000000003',
    'reportNo': 'RB202608280001',
    'sourcePlanItemId': '10000000-0000-0000-0000-000000000004',
    'planId': '10000000-0000-0000-0000-000000000005',
    'planNo': 'SJ202608280001',
    'executionSegmentId': '10000000-0000-0000-0000-000000000006',
    'warehouseId': '10000000-0000-0000-0000-000000000007',
    'goodsId': '10000000-0000-0000-0000-000000000008',
    'goodsCode': 'V51043',
    'goodsName': 'V5多功能三极插座E极插套(酸洗)',
    'colorId': '10000000-0000-0000-0000-000000000012',
    'colorName': '本色',
    'unitId': '10000000-0000-0000-0000-000000000009',
    'unitName': '件',
    'unitRate': 1,
    'reportedQty': 10,
    'passedQty': 0,
    'failedQty': 0,
    'remainingQty': 10,
    'authorizedInboundQty': 0,
    'status': 'PENDING',
    'reportMakerId': '10000000-0000-0000-0000-000000000010',
    'createdAt': '2026-08-28T05:00:00Z',
    'updatedAt': '2026-08-28T05:00:00Z',
  };

  Map<String, dynamic> get _resolvedInspection => {
    ..._inspection,
    'id': '20000000-0000-0000-0000-000000000001',
    'reportNo': 'RB-RESOLVED',
    'passedQty': 10,
    'remainingQty': 0,
    'authorizedInboundQty': 10,
    'status': 'RESOLVED',
  };

  Map<String, dynamic> get _cancelledInspection => {
    ..._inspection,
    'id': '30000000-0000-0000-0000-000000000001',
    'reportNo': 'RB-CANCELLED',
    'remainingQty': 0,
    'status': 'CANCELLED',
  };

  Map<String, dynamic> get _decidedInspection => {
    ..._inspection,
    'passedQty': 10,
    'remainingQty': 0,
    'authorizedInboundQty': 10,
    'status': 'RESOLVED',
  };

  Map<String, dynamic> get _stockedInspection => {
    ..._inspection,
    'id': '40000000-0000-0000-0000-000000000001',
    'reportNo': 'RB-STOCKED',
    'place': 'C-03',
    'preStocked': const {
      'warehouseId': '10000000-0000-0000-0000-000000000007',
      'warehouseName': '成品一仓',
      'place': 'B-02',
    },
  };

  List<Map<String, dynamic>> _itemsFor(String status) {
    return switch (status) {
      'PARTIAL' => [
        if (!decided)
          {
            ..._inspection,
            'status': 'PARTIAL',
            'passedQty': 2,
            'remainingQty': 8,
          },
      ],
      'HISTORY' => [
        if (decided) _decidedInspection,
        _resolvedInspection,
        _cancelledInspection,
      ],
      'RESOLVED' => [if (decided) _decidedInspection, _resolvedInspection],
      'CANCELLED' => [_cancelledInspection],
      'ALL' => [
        if (!decided) _inspection else _decidedInspection,
        _resolvedInspection,
        _cancelledInspection,
      ],
      _ =>
        decided
            ? <Map<String, dynamic>>[]
            : [if (includeStocked) _stockedInspection, _inspection],
    };
  }

  Map<String, dynamic> _detail(String id) {
    return <Map<String, dynamic>>[
      if (!decided) _inspection else _decidedInspection,
      _resolvedInspection,
      _cancelledInspection,
    ].firstWhere((item) => item['id'] == id, orElse: () => _inspection);
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/capability')) {
      capabilityCalls++;
      final pending = capabilityResponse;
      capabilityResponse = null;
      return pending == null ? {'canDecide': canDecide} : pending.future;
    }
    if (path.endsWith('/count')) return const {'count': 1};
    const listPath = '/production/quality-inspections';
    if (path.startsWith('$listPath/') && !path.endsWith('/decisions')) {
      detailCalls++;
      return _detail(path.substring('$listPath/'.length));
    }
    final effectiveQuery = Map<String, dynamic>.from(query ?? const {});
    listQueries.add(effectiveQuery);
    if (listReadGate case final gate?) {
      listReadGate = null;
      await gate.future;
    }
    if (failReloadAfterDecision && decided) {
      throw DioException(
        requestOptions: RequestOptions(path: path),
        type: DioExceptionType.connectionError,
      );
    }
    requestedPage = (effectiveQuery['page'] as num?)?.toInt() ?? 1;
    final status = effectiveQuery['status']?.toString() ?? 'ACTIVE';
    final keyword = effectiveQuery['keyword']?.toString().toLowerCase() ?? '';
    final source = [
      ..._itemsFor(status),
      if (showPoolRows && status == 'ACTIVE')
        {..._stockedInspection, 'reportNo': 'FQC-其他来源'},
    ];
    final fullScope = totalPages > 1 && status == 'ACTIVE' && source.isNotEmpty
        ? [
            for (var index = 0; index < totalPages * 40; index++)
              {
                ...source.first,
                'id': index == 0
                    ? source.first['id']
                    : '90000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
                'reportNo': pageSpecificRows
                    ? 'FQC-PAGE-${index ~/ 40 + 1}-ROW-${index % 40 + 1}'
                    : index == 0
                    ? source.first['reportNo']
                    : 'FQC-EXTRA-$index',
              },
          ]
        : source;
    final items = fullScope
        .where((item) {
          return matchesKeywordSearch([
            item['reportNo'] as String?,
            item['planNo'] as String?,
            item['goodsCode'] as String?,
            item['goodsName'] as String?,
            item['colorName'] as String?,
          ], keyword);
        })
        .toList(growable: false);
    final offset = (requestedPage - 1) * 40;
    final batch = items.skip(offset).take(40).toList();
    if (duplicateSecondPage && requestedPage == 2 && batch.isNotEmpty) {
      batch[0] = {...batch[0], 'id': items.first['id']};
    }
    return {
      'items': batch,
      'page': requestedPage,
      'size': 40,
      'total': items.length,
      'totalPages': (items.length + 39) ~/ 40,
      'readScopeVersion': changedReadScope && requestedPage == 2
          ? 'fqc-v2'
          : 'fqc-v1',
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    if (path == ApiEndpoints.productionQualityInspectionPassAll) {
      batchBody = Map<String, dynamic>.from(body! as Map<String, dynamic>);
      decided = true;
      return {
        'batchId': 'fqc-batch-1',
        'replay': false,
        'processedCount': 1,
        'items': [
          {
            'inspectionId': _inspectionId,
            'decisionEventId': '10000000-0000-0000-0000-000000000011',
            'inspection': _decidedInspection,
          },
        ],
      };
    }
    expect(path, '/production/quality-inspections/$_inspectionId/decisions');
    decisionBody = Map<String, dynamic>.from(body! as Map<String, dynamic>);
    decided = true;
    return {
      'decisionEventId': '10000000-0000-0000-0000-000000000011',
      'inspection': _decidedInspection,
      'replay': false,
    };
  }
}
