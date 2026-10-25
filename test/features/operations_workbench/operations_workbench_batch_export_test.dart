// 采购任务工作台「进行中」段批量导出单据的页面级测试（2026-10-19）：
// 多选勾选（非财务通过的行锁形不可选）、右下悬浮「导出单据(N)」按钮、点击把
// 去重后的单据交给注入的导出能力、导出中按钮带 n/N 进度、未选择时点按钮给
// 出原因而不是无声失效。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/pages/operations_workbench_page.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import '../../helpers/badge_summary_fixture.dart';
import '../../support/filter_segment_tap.dart';

class _FakeGateway implements OperationsWorkbenchGateway {
  _FakeGateway(this.data);

  OperationsWorkbenchData data;

  @override
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    Map<String, String?> columnFilters = const {},
    String? issuedFrom,
    String? issuedTo,
    String? needFrom,
    String? needTo,
  }) async => data;
}

class _OfflineApi extends ApiClient {
  _OfflineApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    throw StateError('offline: $path');
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    throw StateError('offline: $path');
  }
}

OperationsWorkbenchTask _task(
  String id, {
  String? docType,
  String docId = 'doc-1',
  String taskStatus = 'FINANCE_APPROVED',
  String? displayStage,
  String? documentStatus = '1',
}) {
  return OperationsWorkbenchTask(
    taskId: id,
    packageId: 'package-1',
    planId: 'plan-1',
    planNo: 'PP-001',
    warehouseName: '原材料仓',
    goodsCode: 'MAT-$id',
    goodsName: '货品 $id',
    spec: 'φ20',
    colorName: '本色',
    unitName: '件',
    supplyRoute: 'PURCHASE',
    requiredQty: 10,
    allocatedQty: 4,
    fulfilledQty: 2,
    supplyPeggedQty: 4,
    openQty: 8,
    taskStatus: taskStatus,
    displayStage: displayStage,
    needDate: '2026-10-01',
    expectedDate: null,
    exceptionCode: null,
    updatedAt: '2026-10-18T10:00:00+08:00',
    actionDocument: docType == null
        ? null
        : OperationsActionDocument(
            id: docId,
            docType: docType,
            number: 'CD-$docId',
            path: docType == 'PURCHASE_ORDER'
                ? '/purchase/orders/$docId'
                : '/purchase/requests/$docId',
            canView: true,
            canEdit: false,
            status: documentStatus,
          ),
    actionDocItemId: 'item-$id',
    actionDocumentRestricted: false,
  );
}

OperationsWorkbenchData _inProgressData() => OperationsWorkbenchData(
  department: OperationsWorkbenchDepartment.purchase,
  summary: const OperationsWorkbenchSummary(
    totalTasks: 3,
    overdueTasks: 0,
    openTasks: 3,
    openQty: 24,
    statusCounts: {'IN_PROGRESS': 3},
  ),
  items: [
    _task('task-1', docType: 'PURCHASE_ORDER', docId: 'order-1'),
    _task('task-2', docType: 'PURCHASE_ORDER', docId: 'order-2'),
    // 还停在申请阶段的行：导不出采购单，勾选位应换锁图标。
    _task('task-3', docType: 'PURCHASE_REQUEST', docId: 'request-3'),
  ],
  page: 1,
  size: 20,
  total: 3,
  totalPages: 1,
  capabilities: const OperationsWorkbenchCapabilities(),
);

Future<void> _pumpPage(
  WidgetTester tester, {
  required OperationsWorkbenchGateway gateway,
  required OperationsWorkbenchBatchDocExport export,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(_OfflineApi()),
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(
            facts: const {BadgeFact.purchaseTaskInProgress: 3},
          ),
        ),
      ],
      child: MaterialApp(
        home: OperationsWorkbenchPage(
          department: OperationsWorkbenchDepartment.purchase,
          repository: gateway,
          purchaseOrderBatchExport: export,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shared order selection keeps non-exportable rows out of the '
      'floating export action', (tester) async {
    final gateway = _FakeGateway(_inProgressData());
    final calls = <List<({String id, String number})>>[];
    void Function(int done, int total)? progressSink;
    final gate = Completer<void>();
    await _pumpPage(
      tester,
      gateway: gateway,
      export:
          (
            context, {
            required apiClient,
            required documents,
            onProgress,
            stillCurrent,
          }) async {
            calls.add(documents);
            progressSink = onProgress;
            await gate.future;
          },
    );
    await selectFilterSegment(tester, '进行中');
    await tester.pumpAndSettle();

    // Selection is shared with whole-order closure. Export eligibility remains
    // an independent predicate, including when another purpose can select a row.
    final table = tester.widget<MasterDataTableView<OperationsWorkbenchTask>>(
      find.byType(MasterDataTableView<OperationsWorkbenchTask>),
    );
    expect(table.items.map((row) => table.idOf!(row)), [
      'task-1',
      'task-2',
      'task-3',
    ]);
    final button = find.byKey(
      const Key('operations-workbench-purchase-export-docs'),
    );
    expect(button, findsOneWidget);

    // 未选择时按钮灰置，点击给出原因而不是无声失效。
    await tester.tap(button);
    await tester.pump();
    expect(calls, isEmpty);

    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    await tester.tap(find.byType(Checkbox).at(2));
    await tester.pump();
    expect(find.text('导出单据(2)'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).at(3));
    await tester.pump();
    expect(tester.widget<UtenButton>(button).onPressed, isNull);
    await tester.tap(button);
    await tester.pump();
    expect(
      calls,
      isEmpty,
      reason: 'mixed eligibility cannot silently export a subset',
    );
    await tester.tap(find.byType(Checkbox).at(3));
    await tester.pump();
    expect(tester.widget<UtenButton>(button).onPressed, isNotNull);

    await tester.tap(button);
    await tester.pump();
    expect(calls, hasLength(1));
    expect(calls.single.map((doc) => doc.id), ['order-1', 'order-2']);

    // 导出进行中：进度把按钮文案切到 n/N；结束后回到已选计数。
    progressSink?.call(1, 2);
    await tester.pump();
    expect(find.text('导出单据(1/2)'), findsOneWidget);
    gate.complete();
    await tester.pump();
    expect(find.text('导出单据(2)'), findsOneWidget);
  });

  testWidgets('duplicate order documents across rows export only once', (
    tester,
  ) async {
    // 两行任务挂在同一张订货单上：批量导出只应交付一份单据。
    final data = _inProgressData();
    final items = [
      _task('task-1', docType: 'PURCHASE_ORDER', docId: 'order-1'),
      _task('task-2', docType: 'PURCHASE_ORDER', docId: 'order-1'),
    ];
    final gateway = _FakeGateway(
      OperationsWorkbenchData(
        department: data.department,
        summary: data.summary,
        items: items,
        page: 1,
        size: 20,
        total: 2,
        totalPages: 1,
        capabilities: data.capabilities,
      ),
    );
    final calls = <List<({String id, String number})>>[];
    await _pumpPage(
      tester,
      gateway: gateway,
      export:
          (
            context, {
            required apiClient,
            required documents,
            onProgress,
            stillCurrent,
          }) async {
            calls.add(documents);
          },
    );
    await selectFilterSegment(tester, '进行中');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    await tester.tap(find.byType(Checkbox).at(2));
    await tester.pump();
    expect(find.text('导出单据(1)'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('operations-workbench-purchase-export-docs')),
    );
    await tester.pump();
    expect(calls.single, hasLength(1));
    expect(calls.single.single.id, 'order-1');
  });

  testWidgets('only finance-approved orders can be exported, including '
      'amendment review and conflicting approval projections', (tester) async {
    final base = _inProgressData();
    final items = [
      _task('approved', docType: 'ORDER'),
      _task(
        'pending',
        docType: 'PURCHASE_ORDER',
        taskStatus: 'ORDER_PENDING_APPROVAL',
        documentStatus: '0',
      ),
      _task(
        'rejected',
        docType: 'PURCHASE_ORDER',
        taskStatus: 'FINANCE_REJECTED',
        documentStatus: '0',
      ),
      _task(
        'amendment-pending',
        docType: 'PURCHASE_ORDER',
        taskStatus: 'ORDER_PENDING_APPROVAL',
        displayStage: 'FINANCE_REVIEW_PENDING',
      ),
      _task(
        'amendment-rejected',
        docType: 'PURCHASE_ORDER',
        taskStatus: 'FINANCE_REJECTED',
        displayStage: 'FINANCE_REVIEW_REJECTED',
      ),
      _task(
        'stage-conflict',
        docType: 'PURCHASE_ORDER',
        displayStage: 'FINANCE_REVIEW_PENDING',
      ),
      _task(
        'document-conflict',
        docType: 'PURCHASE_ORDER',
        documentStatus: '0',
      ),
      _task(
        'document-unknown',
        docType: 'PURCHASE_ORDER',
        documentStatus: null,
      ),
    ];
    final gateway = _FakeGateway(
      OperationsWorkbenchData(
        department: base.department,
        summary: base.summary,
        items: items,
        page: 1,
        size: 20,
        total: items.length,
        totalPages: 1,
        capabilities: base.capabilities,
      ),
    );
    final calls = <List<({String id, String number})>>[];
    await _pumpPage(
      tester,
      gateway: gateway,
      export:
          (
            context, {
            required apiClient,
            required documents,
            onProgress,
            stillCurrent,
          }) async {
            calls.add(documents);
          },
    );
    await selectFilterSegment(tester, '进行中');
    await tester.pumpAndSettle();
    final table = tester.widget<MasterDataTableView<OperationsWorkbenchTask>>(
      find.byType(MasterDataTableView<OperationsWorkbenchTask>),
    );
    expect(
      table.items.map((row) => table.idOf!(row)),
      items.map((row) => row.id),
    );
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    final exportButton = find.byKey(
      const Key('operations-workbench-purchase-export-docs'),
    );
    expect(tester.widget<UtenButton>(exportButton).onPressed, isNull);
    await tester.tap(exportButton);
    await tester.pump();
    expect(
      calls,
      isEmpty,
      reason:
          'finance review, rejected, conflicting and missing statuses deny export',
    );
    table.onSelectedIdsChanged!({'approved'});
    await tester.pump();
    expect(tester.widget<UtenButton>(exportButton).onPressed, isNotNull);
    await tester.tap(exportButton);
    await tester.pump();
    expect(calls.single.single.id, 'doc-1');
  });

  testWidgets('refreshing a selected order into finance review blocks the '
      'entire export instead of silently exporting the other order', (
    tester,
  ) async {
    final gateway = _FakeGateway(_inProgressData());
    final calls = <List<({String id, String number})>>[];
    await _pumpPage(
      tester,
      gateway: gateway,
      export:
          (
            context, {
            required apiClient,
            required documents,
            onProgress,
            stillCurrent,
          }) async {
            calls.add(documents);
          },
    );
    await selectFilterSegment(tester, '进行中');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('导出单据(2)'), findsOneWidget);
    final base = gateway.data;
    gateway.data = OperationsWorkbenchData(
      department: base.department,
      summary: base.summary,
      items: [
        _task('task-1', docType: 'PURCHASE_ORDER', docId: 'order-1'),
        _task(
          'task-2',
          docType: 'PURCHASE_ORDER',
          docId: 'order-2',
          taskStatus: 'ORDER_PENDING_APPROVAL',
          displayStage: 'FINANCE_REVIEW_PENDING',
        ),
      ],
      page: 1,
      size: 20,
      total: 2,
      totalPages: 1,
      capabilities: base.capabilities,
    );
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('operations-workbench-purchase-export-docs')),
    );
    await tester.pump();
    expect(calls, isEmpty);
    expect(
      ProviderScope.containerOf(
            tester.element(find.byType(OperationsWorkbenchPage)),
          )
          .read(appNotificationProvider)
          .map((notification) => notification.message),
      contains('仅财务已通过的采购订货单可导出，请重新选择'),
    );
  });

  testWidgets('waiting-order segment keeps the batch-order action unchanged', (
    tester,
  ) async {
    // 申请段的批量下单走 canCreatePurchaseOrder 能力门控（既有口径）；
    // 进行中段的批量导出不受该能力约束（上面用例的数据未开此能力也能导）。
    final base = _inProgressData();
    final gateway = _FakeGateway(
      OperationsWorkbenchData(
        department: base.department,
        summary: base.summary,
        items: [
          _task('task-1', docType: 'PURCHASE_REQUEST', docId: 'request-1'),
        ],
        page: 1,
        size: 20,
        total: 1,
        totalPages: 1,
        capabilities: const OperationsWorkbenchCapabilities(
          canCreatePurchaseOrder: true,
        ),
      ),
    );
    await _pumpPage(
      tester,
      gateway: gateway,
      export:
          (
            context, {
            required apiClient,
            required documents,
            onProgress,
            stillCurrent,
          }) async {},
    );
    await selectFilterSegment(tester, '进行中');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('operations-workbench-purchase-export-docs')),
      findsOneWidget,
    );
    await selectFilterSegment(tester, '申请待分解');
    await tester.pumpAndSettle();
    // 申请段的批量按钮是「生成采购订货单」，不是导出。
    expect(
      find.byKey(const Key('operations-workbench-purchase-export-docs')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('operations-workbench-purchase-batch')),
      findsOneWidget,
    );
  });

  testWidgets(
    'without injected export capability shared selection cannot export',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(_OfflineApi()),
            fixedBadgeSummaryOverride(
              badgeSummaryFixture(
                facts: const {BadgeFact.purchaseTaskInProgress: 3},
              ),
            ),
          ],
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.purchase,
              repository: _FakeGateway(_inProgressData()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await selectFilterSegment(tester, '进行中');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('operations-workbench-purchase-export-docs')),
        findsNothing,
      );
      final table = tester.widget<MasterDataTableView<OperationsWorkbenchTask>>(
        find.byType(MasterDataTableView<OperationsWorkbenchTask>),
      );
      table.onSelectedIdsChanged!({'task-1'});
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('operations-workbench-purchase-export-docs')),
        findsNothing,
      );
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(
                const Key('procurement-order-closure-selection-action'),
              ),
            )
            .onPressed,
        isNull,
        reason: 'selection never grants order-closure permission',
      );
    },
  );
}
