import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/quality/pages/production_fqc_handling_page.dart';
import 'package:uten_imp/features/quality/pages/quality_batch_approval_page.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/quality/pages/quality_pending_disposal_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inspection_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../support/detail_summary_tap.dart';

// 合并版待检处置页（IQC 收货单 + FQC 自制产成品统一队列）的widget 测试：
// - 混合队列首屏显示所有授权来源，来源/状态筛选由表头承担；
// - 权限分别门控：无 IQC view 不拉收货单、无 FQC view 不请求 FQC 接口；
// - FQC 行详情 → 登记决定；勾选后「批量审批」进汇总页一次提交报告（2026-09-05）。

const _inspectionId = '10000000-0000-0000-0000-000000000001';
const _reportNo = 'RB202608280001';
const _sheetId = '20000000-0000-0000-0000-000000000001';
const _sheetNo = 'FQC20260828000001';

Future<void> _pumpPage(
  WidgetTester tester, {
  required _FqcApi api,
  required _FakeIqcRepository iqc,
  required Set<String> permissions,
  List<FormDraft>? drafts,
  ValueChanged<QualityBatchApprovalSelection>? onBatchSelection,
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (drafts != null)
          formDraftsProvider.overrideWith(() => _Drafts(drafts)),
        apiClientProvider.overrideWithValue(api),
        procurementInspectionRepositoryProvider.overrideWithValue(iqc),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      // 带路由壳：2026-09-05 起「批量审批」会 push 汇总页。
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const QualityPendingDisposalPage(),
            ),
            GoRoute(
              path: RouteName.warehouseInspectionBatchApproval,
              builder: (_, state) {
                final selection = state.extra is QualityBatchApprovalSelection
                    ? state.extra! as QualityBatchApprovalSelection
                    : const QualityBatchApprovalSelection();
                if (onBatchSelection != null) {
                  onBatchSelection(selection);
                  return const Scaffold(body: Text('已进入批量审批'));
                }
                return QualityBatchApprovalPage(selection: selection);
              },
            ),
            // 2026-09-12 弹窗改页：FQC 检查单/单任务办理页。
            GoRoute(
              path: '${RouteName.productionFqcSheetHandlingBase}/:sheetId',
              builder: (_, state) => ProductionFqcSheetHandlingPage(
                sheetId: state.pathParameters['sheetId']!,
              ),
            ),
            GoRoute(
              path:
                  '${RouteName.productionFqcInspectionHandlingBase}/:inspectionId',
              builder: (_, state) => ProductionFqcInspectionPage(
                inspectionId: state.pathParameters['inspectionId']!,
                extra: state.extra,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _doubleTapRow(WidgetTester tester, String text) async {
  final row = find.text(text);
  await tester.tap(row);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(row);
  await tester.pumpAndSettle();
}

Set<String> get _bothViewPerms => {
  Perm.procurementInspectionView,
  Perm.productionQualityInspectionView,
  Perm.productionQualityInspectionApprove,
};

MasterDataTableView<dynamic> _queueTable(WidgetTester tester) =>
    tester.widget(find.byKey(const Key('iqc-receipt-table')));

Finder _queueSearchField() => find.descendant(
  of: find.byKey(const Key('iqc-search')),
  matching: find.byType(TextField),
);

Future<void> _selectQueueFilter(
  WidgetTester tester,
  String key,
  String? value,
) async {
  _queueTable(tester).onFilterChanged(key, value);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('检验填写草稿仍在原待检分类原行，双击恢复原检查单', (tester) async {
    final spec = FormDraftCatalog.fqcSheet.spec(
      route: RouteName.productionFqcSheetHandling(_sheetId),
    );
    final draft = FormDraft(
      id: 'quality-input',
      title: '原检查单填写',
      module: spec.module,
      route: spec.route,
      permission: spec.permission,
      data: const {},
      updatedAt: DateTime.utc(2026, 10, 11),
    );
    await _pumpPage(
      tester,
      api: _FqcApi(withSheet: true),
      iqc: _FakeIqcRepository(),
      permissions: _bothViewPerms,
      drafts: [draft],
    );
    expect(find.text('成品草稿'), findsOneWidget);
    expect(find.text(_sheetNo), findsOneWidget);
    expect(find.text('CJ20260822000001'), findsOneWidget);
    await _selectQueueFilter(tester, 'status', '成品草稿');
    expect(find.text(_sheetNo), findsOneWidget);
    expect(find.text('CJ20260822000001'), findsNothing);
    await _selectQueueFilter(tester, 'status', null);
    expect(find.text(_sheetNo), findsOneWidget);
    expect(find.text('CJ20260822000001'), findsOneWidget);
    await _doubleTapRow(tester, _sheetNo);
    final opened = GoRouterState.of(
      tester.element(find.byType(ProductionFqcSheetHandlingPage)),
    ).uri;
    expect(opened.path, RouteName.productionFqcSheetHandling(_sheetId));
    expect(opened.queryParameters['draftId'], 'quality-input');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'mixed queue keeps all sources visible and filters from headers',
    (tester) async {
      final api = _FqcApi();
      final iqc = _FakeIqcRepository();
      await _pumpPage(tester, api: api, iqc: iqc, permissions: _bothViewPerms);

      // 统一队列表同时出现两类行。
      expect(find.byKey(const Key('iqc-receipt-table')), findsOneWidget);
      expect(find.text('CJ20260822000001'), findsOneWidget);
      expect(find.text('WT20260823000002'), findsOneWidget);
      expect(find.text(_reportNo), findsOneWidget);
      expect(find.byType(UtenSegmentRow<String>), findsNothing);
      expect(find.text('采购待检'), findsOneWidget);
      expect(find.text('委外待检'), findsOneWidget);
      expect(find.text('成品待检'), findsOneWidget);
      expect(
        _queueTable(tester).facets['docType']?.map((bucket) => bucket.value),
        containsAll(['PURCHASE', 'SUBCONTRACT', 'FQC']),
      );

      // 2026-10-08 根治：IQC 收货单行的「货品名称/待检数量」显示服务端货品摘要
      // 与按单位分组的数量文本，不再整列「—」。
      expect(find.text('PVC粒料 (WL001 · 蓝色)'), findsOneWidget);
      expect(find.text('5 个'), findsOneWidget);
      expect(find.text('支架 (WL002)'), findsOneWidget);

      // 类型表头筛选只留 FQC；无需在表格上方找重复来源分段。
      await _selectQueueFilter(tester, 'docType', 'FQC');
      expect(find.text('CJ20260822000001'), findsNothing);
      expect(find.text('WT20260823000002'), findsNothing);
      expect(find.text(_reportNo), findsOneWidget);
      expect(find.text('暂无自制产成品待检任务'), findsNothing);

      // 清除表头来源筛选回到完整队列。
      await _selectQueueFilter(tester, 'docType', null);
      expect(find.text('CJ20260822000001'), findsOneWidget);
      expect(find.text(_reportNo), findsOneWidget);

      // 搜索跨域：按报工单号收窄到 FQC 行。
      await tester.enterText(_queueSearchField(), _reportNo);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('CJ20260822000001'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('iqc-receipt-table')),
          matching: find.text(_reportNo),
        ),
        findsOneWidget,
      );

      // 搜索也认货品摘要（2026-10-08 起收货单行带 goodsSummary）：按来料名称
      // 收窄到 IQC 行。
      await tester.enterText(_queueSearchField(), 'PVC粒料');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('iqc-receipt-table')),
          matching: find.text('CJ20260822000001'),
        ),
        findsOneWidget,
      );
      expect(find.text(_reportNo), findsNothing);
    },
  );

  testWidgets('FQC row detail leads to decision and local removal', (
    tester,
  ) async {
    final api = _FqcApi();
    await _pumpPage(
      tester,
      api: api,
      iqc: _FakeIqcRepository(),
      permissions: _bothViewPerms,
    );

    await _doubleTapRow(tester, _reportNo);
    // 2026-09-12 弹窗改页：进入 FQC 单任务办理页（详情事实 + 决定表单）。
    expect(find.byKey(const Key('fqc-inspection-facts-table')), findsOneWidget);
    expect(
      find.byKey(const Key('fqc-inspection-submit-report')),
      findsOneWidget,
    );

    // 默认全合格 → 提交报告 → 总结确认。
    await tester.tap(find.byKey(const Key('fqc-inspection-submit-report')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(api.decisionBody?['decision'], 'PASS');
    expect(api.decisionBody?['passQty'], 10);
    // 决定成功自动带结果返回：已决定任务行消失，IQC 行仍在。
    await tester.pumpAndSettle();
    expect(find.text(_reportNo), findsNothing);
    expect(find.text('CJ20260822000001'), findsOneWidget);
  });

  testWidgets('来源和状态表头筛选覆盖全队列，清空后保留分页', (tester) async {
    final api = _FqcApi();
    final iqc = _FakeIqcRepository(
      additionalReceipts: [
        for (var index = 0; index < 10; index++)
          PendingInspectionReceipt(
            receiptType: 'PURCHASE',
            receiptId: 'extra-receipt-$index',
            billNo: 'CJ-EXTRA-$index',
            itemCount: 1,
          ),
      ],
    );
    await _pumpPage(tester, api: api, iqc: iqc, permissions: _bothViewPerms);
    expect(_queueTable(tester).currentPage, 1);
    expect(_queueTable(tester).totalPages, 2);
    expect(find.text(_reportNo), findsNothing);
    expect(
      _queueTable(
        tester,
      ).facets['status']?.singleWhere((bucket) => bucket.value == '成品待检').count,
      1,
    );

    // FQC 在初始第二页，筛选仍必须找到它并回第一页。
    await _selectQueueFilter(tester, 'status', '成品待检');
    expect(find.text(_reportNo), findsOneWidget);
    expect(_queueTable(tester).currentPage, 1);
    expect(_queueTable(tester).totalPages, 1);
    await _selectQueueFilter(tester, 'status', null);
    await _selectQueueFilter(tester, 'docType', 'FQC');
    expect(find.text(_reportNo), findsOneWidget);
    await _selectQueueFilter(tester, 'docType', null);
    expect(_queueTable(tester).totalPages, 2);
    _queueTable(tester).onPageChange!(2);
    await tester.pumpAndSettle();
    expect(find.text(_reportNo), findsOneWidget);
    expect(_queueTable(tester).currentPage, 2);
    expect(iqc.pendingReceiptsCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同 UUID 的采购、委外、检查单和 FQC 行不串身份或批量来源', (tester) async {
    QualityBatchApprovalSelection? submittedSelection;
    await _pumpPage(
      tester,
      api: _MixedIdentityFqcApi(),
      iqc: _FakeIqcRepository(
        receiptsOverride: const [
          PendingInspectionReceipt(
            receiptType: 'PURCHASE',
            receiptId: _inspectionId,
            billNo: 'PURCHASE-SAME-ID',
            itemCount: 1,
          ),
          PendingInspectionReceipt(
            receiptType: 'SUBCONTRACT',
            receiptId: _inspectionId,
            billNo: 'SUBCONTRACT-SAME-ID',
            itemCount: 1,
          ),
        ],
      ),
      permissions: {..._bothViewPerms, Perm.procurementInspectionHandle},
      onBatchSelection: (selection) => submittedSelection = selection,
    );
    final dynamic table = _queueTable(tester);
    const purchaseId = 'iqc:PURCHASE:$_inspectionId';
    const subcontractId = 'iqc:SUBCONTRACT:$_inspectionId';
    const sheetId = 'sheet:$_inspectionId';
    const fqcId = 'fqc:$_inspectionId';
    final rows = _queueTable(tester).items;
    final rowKeys = rows.map((row) {
      // The private row type requires invocation without widening its callback.
      // ignore: avoid_dynamic_calls
      return table.rowKeyOf(row) as String;
    }).toSet();
    expect(rowKeys, {purchaseId, subcontractId, sheetId, fqcId});
    expect(find.text('PURCHASE-SAME-ID'), findsOneWidget);
    expect(find.text('SUBCONTRACT-SAME-ID'), findsOneWidget);
    expect(find.text(_sheetNo), findsOneWidget);
    expect(find.text(_reportNo), findsOneWidget);

    // 同原 UUID 只能勾中本来源行，不能把另一张单据连带选中。
    _queueTable(tester).onSelectedIdsChanged!({purchaseId});
    await tester.pumpAndSettle();
    expect(_queueTable(tester).selectedIds, {purchaseId});
    expect(find.text('批量审批(1)'), findsOneWidget);
    _queueTable(tester).onSelectedIdsChanged!({
      purchaseId,
      subcontractId,
      sheetId,
      fqcId,
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(_queueTable(tester).selectedIds, {
      purchaseId,
      subcontractId,
      sheetId,
      fqcId,
    });
    await tester.tap(find.byKey(const Key('quality-batch-approval')));
    await tester.pumpAndSettle();
    expect(
      submittedSelection?.receipts.map(
        (receipt) => '${receipt.receiptType}:${receipt.receiptId}',
      ),
      ['PURCHASE:$_inspectionId', 'SUBCONTRACT:$_inspectionId'],
    );
    expect(submittedSelection?.sheets.single.id, _inspectionId);
    expect(submittedSelection?.inspections.single.id, _inspectionId);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FQC 请求 500 被服务端归一为 100 后继续读取两域次页', (tester) async {
    final api = _PagedFqcApi(sheetCount: 105, looseCount: 102);
    await _pumpPage(
      tester,
      api: api,
      iqc: _FakeIqcRepository(),
      permissions: _bothViewPerms,
    );
    expect(api.sheetPages, [1, 2]);
    expect(api.loosePages, [1, 2]);
    expect(api.sheetRequestedSizes, [500, 100]);
    expect(api.looseRequestedSizes, [500, 100]);
    expect(find.textContaining('表头筛选仅覆盖已加载任务'), findsNothing);

    // 两个来源的第 101 行均不在各自服务端首批 100 条里。
    await tester.enterText(_queueSearchField(), 'FQC-PAGE-101');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('iqc-receipt-table')),
        matching: find.text('FQC-PAGE-101'),
      ),
      findsOneWidget,
    );
    await tester.enterText(_queueSearchField(), 'REPORT-PAGE-101');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('iqc-receipt-table')),
        matching: find.text('REPORT-PAGE-101'),
      ),
      findsOneWidget,
    );
    expect(_queueTable(tester).currentPage, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FQC 各域仍只加载 500，截断提示区分总数和已加载范围', (tester) async {
    final api = _PagedFqcApi(sheetCount: 601, looseCount: 602);
    await _pumpPage(
      tester,
      api: api,
      iqc: _FakeIqcRepository(),
      permissions: _bothViewPerms,
    );
    expect(api.sheetPages, [1, 2, 3, 4, 5]);
    expect(api.loosePages, [1, 2, 3, 4, 5]);
    expect(find.textContaining('待检任务共 1203 条，当前已加载 1000 条'), findsOneWidget);
    expect(find.textContaining('各最多加载 500 条'), findsOneWidget);
    expect(find.textContaining('表头筛选仅覆盖已加载任务'), findsOneWidget);
    await tester.enterText(_queueSearchField(), 'FQC-PAGE-500');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('iqc-receipt-table')),
        matching: find.text('FQC-PAGE-500'),
      ),
      findsOneWidget,
    );
    await tester.enterText(_queueSearchField(), 'FQC-PAGE-501');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('iqc-receipt-table')),
        matching: find.text('FQC-PAGE-501'),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('勾选 FQC 任务 → 批量审批汇总页一次提交（原子 pass-all）', (tester) async {
    final api = _FqcApi();
    await _pumpPage(
      tester,
      api: api,
      iqc: _FakeIqcRepository(),
      permissions: _bothViewPerms,
    );

    await tester.tap(find.text(_reportNo));
    await tester.pumpAndSettle();
    final action = find.byKey(const Key('quality-batch-approval'));
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();

    // 汇总页：FQC 区默认勾选（全部合格），底部提交报告。
    expect(
      find.byKey(const Key('batch-approval-submit-report')),
      findsOneWidget,
    );
    expect(find.textContaining('勾选即全部合格'), findsOneWidget);
    await tester.tap(find.byKey(const Key('batch-approval-submit-report')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(api.batchBody?['inspectionIds'], [_inspectionId]);
    expect(
      api.batchBody?['idempotencyKey'] as String?,
      startsWith('fqc-batch-approval-'),
    );
  });

  testWidgets('V547 检查单行：一行一张单，双击进检查单办理并全部合格', (tester) async {
    final api = _FqcApi(withSheet: true);
    await _pumpPage(
      tester,
      api: api,
      iqc: _FakeIqcRepository(),
      permissions: _bothViewPerms,
    );

    // 队列显示检查单号而不是逐条报工任务，状态保留来源。
    expect(find.text(_sheetNo), findsOneWidget);
    expect(find.text(_reportNo), findsNothing);
    expect(find.text('10 件'), findsOneWidget);
    expect(find.text('成品待检'), findsOneWidget);

    await _doubleTapRow(tester, _sheetNo);
    // 2026-09-12 弹窗改页：进入检查单办理页（对齐采购 IQC 处置页范式）。
    expect(find.byKey(const Key('fqc-sheet-header-table')), findsOneWidget);
    expect(api.sheetDetailCalls, 1);
    final summary = find.byKey(
      const ValueKey('fqc-sheet-summary-$_sheetId'),
      skipOffstage: false,
    );
    await setDetailSummaryExpanded(tester, summary: summary);
    await expectVisibleDetailSummaryField(
      tester,
      '登记备注',
      '整托入库',
      summary: summary,
    );
    expect(api.sheetDetailCalls, 1);
    expect(api.postPaths, isEmpty);
    await setDetailSummaryExpanded(tester, summary: summary, expanded: false);
    expect(find.text('CP-A-01'), findsWidgets);
    // 默认全勾 + 合格默认=待检：整份报告一次提交。
    final submit = find.byKey(
      const Key('fqc-sheet-submit-report'),
      skipOffstage: false,
    );
    await tester.ensureVisible(submit);
    await tester.pumpAndSettle();
    expect(submit.hitTestable(), findsOneWidget);
    await tester.tap(submit.hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 整批判定：合格 10、不良 0(服务端按瀑布分给批内各份)。
    expect(api.decisionBody?['passQty'], 10);
    expect(api.decisionBody?['failQty'], 0);
    expect(api.postPaths, [
      '${ApiEndpoints.productionQualityInspections}/decisions/report',
    ]);
    // 单内已无待检行 → 完成态；返回队列后检查单行消失。
    expect(find.text('本检查单当前待检已全部处理完成'), findsOneWidget);
    await tester.tap(find.byType(UtenBackButton));
    await tester.pumpAndSettle();
    expect(find.text(_sheetNo), findsNothing);
    expect(find.text('CJ20260822000001'), findsOneWidget);
  });

  testWidgets('V597 先入库后检的检查单：队列储放位置标红，办理页顶部标红并逐行给出库位', (tester) async {
    final api = _FqcApi(withSheet: true, preStocked: true);
    await _pumpPage(
      tester,
      api: api,
      iqc: _FakeIqcRepository(),
      permissions: _bothViewPerms,
    );

    // 队列「仓库 / 库位号」两列（2026-09-18 起）：检查单按已上架行标红，
    // 仓库=登记成品仓；IQC 单未上架仍是「待检区」。
    expect(find.text('成品仓'), findsOneWidget);
    expect(find.text('待检区'), findsWidgets);

    await _doubleTapRow(tester, _sheetNo);
    expect(
      find.byKey(const Key('fqc-sheet-pre-stocked-notice')),
      findsOneWidget,
    );
    expect(find.text('货品已入库，需到对应储放区域检查'), findsOneWidget);
    expect(
      find.textContaining('V5多功能三极插座E极插套(酸洗) → 成品仓 / CP-A-01'),
      findsOneWidget,
    );
    expect(find.text('已入库 · 成品仓 / CP-A-01'), findsOneWidget);
  });

  testWidgets('FQC-only account skips IQC fetch and source facets', (
    tester,
  ) async {
    final api = _FqcApi();
    final iqc = _FakeIqcRepository();
    await _pumpPage(
      tester,
      api: api,
      iqc: iqc,
      permissions: {Perm.productionQualityInspectionView},
    );

    expect(iqc.pendingReceiptsCalls, 0);
    expect(find.text('采购收货'), findsNothing);
    expect(find.text('委外回厂'), findsNothing);
    expect(find.text('成品待检'), findsOneWidget);
    expect(
      _queueTable(tester).facets['docType']?.map((bucket) => bucket.value),
      ['FQC'],
    );
    expect(find.text(_reportNo), findsOneWidget);
    // 无审批权限 → 不可选、无批量动作。
    expect(find.byKey(const Key('quality-batch-approval')), findsNothing);
  });

  testWidgets('IQC-only account never requests FQC endpoints', (tester) async {
    final api = _FqcApi();
    await _pumpPage(
      tester,
      api: api,
      iqc: _FakeIqcRepository(),
      permissions: {Perm.procurementInspectionView},
    );

    expect(api.listCalls, 0);
    expect(api.capabilityCalls, 0);
    expect(find.text('自制产成品'), findsNothing);
    expect(find.text('CJ20260822000001'), findsOneWidget);
    expect(find.text('WT20260823000002'), findsOneWidget);
  });

  testWidgets(
    'status header can narrow and clear a mixed queue without source segments',
    (tester) async {
      await _pumpPage(
        tester,
        api: _FqcApi(),
        iqc: _FakeIqcRepository(),
        permissions: _bothViewPerms,
      );

      expect(find.byType(UtenSegmentRow<String>), findsNothing);
      expect(
        _queueTable(tester).facets['status']?.map((bucket) => bucket.value),
        containsAll(['采购待检', '委外待检', '成品待检']),
      );
      await _selectQueueFilter(tester, 'status', '委外待检');
      expect(find.text('WT20260823000002'), findsOneWidget);
      expect(find.text('CJ20260822000001'), findsNothing);
      expect(find.text(_reportNo), findsNothing);
      await _selectQueueFilter(tester, 'status', null);
      expect(find.text('CJ20260822000001'), findsOneWidget);
      expect(find.text('WT20260823000002'), findsOneWidget);
      expect(find.text(_reportNo), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Drafts extends FormDraftsNotifier {
  _Drafts(this.values);
  final List<FormDraft> values;
  @override
  List<FormDraft> build() => values;
}

class _FakeIqcRepository implements ProcurementInspectionRepository {
  _FakeIqcRepository({
    this.additionalReceipts = const [],
    this.receiptsOverride,
  });

  final List<PendingInspectionReceipt> additionalReceipts;
  final List<PendingInspectionReceipt>? receiptsOverride;
  final List<PendingInspectionReceipt> receipts = const [
    PendingInspectionReceipt(
      receiptType: 'PURCHASE',
      receiptId: 'receipt-1',
      billNo: 'CJ20260822000001',
      supplierName: '采购供应商',
      itemCount: 1,
      pendingBaseQty: 5,
      goodsSummary: 'PVC粒料 (WL001 · 蓝色)',
      pendingQtyText: '5 个',
    ),
    PendingInspectionReceipt(
      receiptType: 'SUBCONTRACT',
      receiptId: 'receipt-2',
      billNo: 'WT20260823000002',
      supplierName: '委外加工商',
      itemCount: 1,
      pendingBaseQty: 3,
      goodsSummary: '支架 (WL002)',
      pendingQtyText: '3 个',
    ),
  ];

  int pendingReceiptsCalls = 0;

  @override
  Future<List<PendingInspectionReceipt>> pendingReceipts() async {
    pendingReceiptsCalls++;
    return [...(receiptsOverride ?? receipts), ...additionalReceipts];
  }

  @override
  Future<List<ProcurementInspectionItem>> items(
    String receiptType,
    String receiptId,
  ) async => const [];

  @override
  Future<void> dispose({
    required String receiptType,
    required String receiptId,
    required String inspectionItemId,
    required String action,
    double? baseQty,
    String? reason,
    required String idempotencyKey,
  }) async {}

  @override
  Future<void> passBatch({
    required String receiptType,
    required String receiptId,
    required List<ProcurementInspectionBatchPassItem> items,
    String? reason,
  }) async {}

  @override
  Future<void> decideBatch({
    required String receiptType,
    required String receiptId,
    required List<ProcurementInspectionDecideItem> items,
    String? reason,
  }) async {}

  @override
  Future<void> decideReport({
    required List<ProcurementInspectionReportReceipt> receipts,
    String? reason,
  }) async {}
}

class _MixedIdentityFqcApi extends _FqcApi {
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.productionQualityInspectionSheets) {
      return {
        'items': [
          {..._sheet, 'id': _inspectionId},
        ],
        'page': 1,
        'size': 100,
        'total': 1,
        'totalPages': 1,
      };
    }
    return super.get(path, query: query);
  }
}

class _PagedFqcApi extends _FqcApi {
  _PagedFqcApi({required this.sheetCount, required this.looseCount});

  final int sheetCount;
  final int looseCount;
  final List<int> sheetPages = [];
  final List<int> loosePages = [];
  final List<int> sheetRequestedSizes = [];
  final List<int> looseRequestedSizes = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final isSheet = path == ApiEndpoints.productionQualityInspectionSheets;
    if (!isSheet && path != ApiEndpoints.productionQualityInspections) {
      return super.get(path, query: query);
    }
    final page = query?['page'] as int? ?? 1;
    final requestedSize = query?['size'] as int? ?? 40;
    final size = requestedSize.clamp(1, 100).toInt();
    final count = isSheet ? sheetCount : looseCount;
    (isSheet ? sheetPages : loosePages).add(page);
    (isSheet ? sheetRequestedSizes : looseRequestedSizes).add(requestedSize);
    if (!isSheet) expect(query?['sheet'], 'NONE');
    final start = (page - 1) * size;
    final end = (start + size).clamp(0, count).toInt();
    return {
      'items': [
        for (var index = start; index < end; index++)
          if (isSheet)
            {
              ..._sheet,
              'id': 'sheet-page-${index + 1}',
              'sheetNo': 'FQC-PAGE-${index + 1}',
            }
          else
            {
              ..._inspection,
              'id': 'loose-page-${index + 1}',
              'reportNo': 'REPORT-PAGE-${index + 1}',
            },
      ],
      'page': page,
      'size': size,
      'total': count,
      'totalPages': (count + size - 1) ~/ size,
    };
  }
}

class _FqcApi extends ApiClient {
  _FqcApi({this.withSheet = false, this.preStocked = false}) : super(Dio());

  /// true = 待检任务归属一张品质检查单（V547），队列显示检查单行而非任务行。
  final bool withSheet;

  /// true = 仓库登记时已先入库上架(V597)，检查单与行都带储放位置。
  final bool preStocked;
  int sheetDetailCalls = 0;

  Map<String, dynamic>? decisionBody;
  Map<String, dynamic>? batchBody;
  bool decided = false;
  int listCalls = 0;
  int capabilityCalls = 0;
  final List<String> postPaths = [];

  Map<String, dynamic> get _inspection => const {
    'id': _inspectionId,
    'sourceReportId': '10000000-0000-0000-0000-000000000002',
    'sourceReportItemId': '10000000-0000-0000-0000-000000000003',
    'reportNo': _reportNo,
    'planNo': 'SJ202608280001',
    'goodsCode': 'V51043',
    'goodsName': 'V5多功能三极插座E极插套(酸洗)',
    'colorName': '本色',
    'unitName': '件',
    'reportedQty': 10,
    'passedQty': 0,
    'failedQty': 0,
    'remainingQty': 10,
    'authorizedInboundQty': 0,
    'status': 'PENDING',
    'createdAt': '2026-08-28T05:00:00Z',
    'updatedAt': '2026-08-28T05:00:00Z',
  };

  Map<String, dynamic> get _decidedInspection => {
    ..._inspection,
    'passedQty': 10,
    'remainingQty': 0,
    'authorizedInboundQty': 10,
    'status': 'RESOLVED',
  };

  Map<String, dynamic> get _sheetInspection => {
    ..._inspection,
    'sheetId': _sheetId,
    'sheetNo': _sheetNo,
    'warehouseName': '成品仓',
    'place': 'CP-A-01',
    'registrationRemark': '整托入库',
    'receiverName': '仓库管理员',
    if (preStocked)
      'preStocked': {
        'warehouseId': 'warehouse-1',
        'warehouseName': '成品仓',
        'place': 'CP-A-01',
        'stockedByName': '仓库管理员',
      },
  };

  Map<String, dynamic> get _sheet => {
    'id': _sheetId,
    'sheetNo': _sheetNo,
    'warehouseId': 'warehouse-1',
    'warehouseName': '成品仓',
    'receiverName': '仓库管理员',
    'remark': '整托入库',
    'sourceKind': 'ARRIVAL_SINGLE',
    'itemCount': 1,
    'activeCount': decided ? 0 : 1,
    'pendingQtyText': decided ? null : '10 件',
    'reportNos': _reportNo,
    'goodsSummary': 'V5多功能三极插座E极插套(酸洗)',
    'status': decided ? 'CLOSED' : 'ACTIVE',
    'createdAt': '2026-08-28T05:00:00Z',
    if (preStocked) 'preStockedItemCount': decided ? 0 : 1,
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/capability')) {
      capabilityCalls++;
      return {'canDecide': true};
    }
    if (path.endsWith('/count')) return {'count': decided ? 0 : 1};
    const listPath = '/production/quality-inspections';
    if (path == '$listPath/sheets') {
      // V547 检查单队列：无检查单的历史任务不在这里；有检查单时一行一张单。
      final items = withSheet && !decided ? [_sheet] : <Map<String, dynamic>>[];
      return {
        'items': items,
        'page': 1,
        'size': 500,
        'total': items.length,
        'totalPages': items.isEmpty ? 0 : 1,
      };
    }
    if (path == '$listPath/sheets/$_sheetId') {
      sheetDetailCalls++;
      final row = decided ? _decidedInspection : _sheetInspection;
      return {
        'sheet': _sheet,
        'inspections': [row],
        // ADR-148：办理页一行 = 一批实物；这里一份自成一批(批号 = 任务号)。
        'lots': [_lotOf(row)],
      };
    }
    if (path.startsWith('$listPath/') && !path.endsWith('/decisions')) {
      return withSheet ? _sheetInspection : _inspection;
    }
    listCalls++;
    // sheet=NONE：只列无检查单的任务；归属检查单的任务不在这里出现。
    final items = decided || withSheet
        ? <Map<String, dynamic>>[]
        : [_inspection];
    return {
      'items': items,
      'page': 1,
      'size': 500,
      'total': items.length,
      'totalPages': 1,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    postPaths.add(path);
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
    if (path ==
        '${ApiEndpoints.productionQualityInspections}/decisions/report') {
      final item = Map<String, dynamic>.from(
        ((body! as Map)['items'] as List).single as Map,
      );
      decisionBody = item;
      decided = true;
      return {
        'items': [
          {
            'targetType': item['targetType'],
            'targetId': item['targetId'],
            'idempotencyKey': item['idempotencyKey'],
            'commandId': '10000000-0000-0000-0000-000000000012',
            'lot': _lotOf(_decidedInspection),
            'replay': false,
          },
        ],
      };
    }
    decisionBody = Map<String, dynamic>.from(body! as Map<String, dynamic>);
    decided = true;
    // 检查单办理页按批判定；单任务办理页(无检查单历史任务)逐份判定。
    if (path ==
        '/production/quality-inspections/lots/$_inspectionId/decisions') {
      return {
        'lotCommandId': '10000000-0000-0000-0000-000000000012',
        'lot': _lotOf(_decidedInspection),
        'replay': false,
      };
    }
    expect(path, '/production/quality-inspections/$_inspectionId/decisions');
    return {
      'decisionEventId': '10000000-0000-0000-0000-000000000011',
      'inspection': _decidedInspection,
      'replay': false,
    };
  }

  Map<String, dynamic> _lotOf(Map<String, dynamic> row) => {
    'lotId': row['id'],
    'sourceReportId': row['sourceReportId'],
    'reportNo': row['reportNo'],
    'planNo': row['planNo'],
    'goodsCode': row['goodsCode'],
    'goodsName': row['goodsName'],
    'colorName': row['colorName'],
    'unitName': row['unitName'],
    'reportedQty': row['reportedQty'],
    'passedQty': row['passedQty'],
    'failedQty': row['failedQty'],
    'remainingQty': row['remainingQty'],
    'status': row['status'],
    'warehouseName': row['warehouseName'],
    'place': row['place'],
    if (row['preStocked'] != null) 'preStocked': row['preStocked'],
    'members': [
      {
        'inspectionId': row['id'],
        'sourceReportItemId': row['sourceReportItemId'],
        'sliceRank': 0,
        'kind': 'DEMAND',
        'reportedQty': row['reportedQty'],
        'passedQty': row['passedQty'],
        'failedQty': row['failedQty'],
        'remainingQty': row['remainingQty'],
        'status': row['status'],
      },
    ],
  };
}
