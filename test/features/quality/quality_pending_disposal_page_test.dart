import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
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
import 'package:uten_imp/features/warehouse/repositories/procurement_inspection_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

// 合并版待检处置页（IQC 收货单 + FQC 自制产成品统一队列）的widget 测试：
// - 四分段（全部待检单/采购收货/委外回厂/自制产成品）与红色圆数字徽章；
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
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        procurementInspectionRepositoryProvider.overrideWithValue(iqc),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      // 带路由壳：2026-09-05 起「批量审批」会 push 汇总页。
      child: MaterialApp.router(
        routerConfig: GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const QualityPendingDisposalPage(),
            ),
            GoRoute(
              path: RouteName.warehouseInspectionBatchApproval,
              builder: (_, state) => QualityBatchApprovalPage(
                selection: state.extra is QualityBatchApprovalSelection
                    ? state.extra! as QualityBatchApprovalSelection
                    : const QualityBatchApprovalSelection(),
              ),
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

Finder _segmentText(String text) => find.descendant(
  of: find.byType(SegmentedButton<String>),
  matching: find.text(text),
);

Finder _segmentBadge(String text) => _segmentText(text);

void main() {
  testWidgets('merged queue mixes IQC receipts and FQC tasks with badges', (
    tester,
  ) async {
    final api = _FqcApi();
    final iqc = _FakeIqcRepository();
    await _pumpPage(tester, api: api, iqc: iqc, permissions: _bothViewPerms);

    // 统一队列表同时出现两类行。
    expect(find.byKey(const Key('iqc-receipt-table')), findsOneWidget);
    expect(find.text('CJ20260822000001'), findsOneWidget);
    expect(find.text('WT20260823000002'), findsOneWidget);
    expect(find.text(_reportNo), findsOneWidget);
    expect(_segmentText('自制产成品'), findsOneWidget);

    // 分段红色圆数字徽章只挂可办的类型分段（各 1）；「全部待检单」不挂徽章。
    expect(_segmentBadge('1'), findsNWidgets(3));
    expect(_segmentBadge('3'), findsNothing);

    // 「自制产成品」分段只留 FQC 行。
    await tester.tap(_segmentText('自制产成品'));
    await tester.pumpAndSettle();
    expect(find.text('CJ20260822000001'), findsNothing);
    expect(find.text('WT20260823000002'), findsNothing);
    expect(find.text(_reportNo), findsOneWidget);
    expect(find.text('暂无自制产成品待检任务'), findsNothing);

    // 回到全部。
    await tester.tap(_segmentText('全部待检单'));
    await tester.pumpAndSettle();
    expect(find.text('CJ20260822000001'), findsOneWidget);
    expect(find.text(_reportNo), findsOneWidget);

    // 搜索跨域：按报工单号收窄到 FQC 行。
    await tester.enterText(find.byType(TextField), _reportNo);
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
  });

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

    // 队列显示检查单号而不是逐条报工任务；徽章按单计数。
    expect(find.text(_sheetNo), findsOneWidget);
    expect(find.text(_reportNo), findsNothing);
    expect(find.text('10 件'), findsOneWidget);
    expect(_segmentBadge('1'), findsNWidgets(3));

    await _doubleTapRow(tester, _sheetNo);
    // 2026-09-12 弹窗改页：进入检查单办理页（对齐采购 IQC 处置页范式）。
    expect(find.byKey(const Key('fqc-sheet-header-table')), findsOneWidget);
    expect(api.sheetDetailCalls, 1);
    expect(find.textContaining('登记备注：整托入库'), findsOneWidget);
    expect(find.text('CP-A-01'), findsWidgets);
    // 默认全勾 + 合格默认=待检：一次提交即「全部合格」（逐行 decide）。
    await tester.tap(find.byKey(const Key('fqc-sheet-submit-report')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(api.decisionBody?['decision'], 'PASS');
    expect(api.decisionBody?['passQty'], 10);
    // 单内已无待检行 → 完成态；返回队列后检查单行消失。
    expect(find.text('本检查单待检已全部处理完成'), findsOneWidget);
    await tester.tap(find.byType(UtenBackButton));
    await tester.pumpAndSettle();
    expect(find.text(_sheetNo), findsNothing);
    expect(find.text('CJ20260822000001'), findsOneWidget);
  });

  testWidgets('FQC-only account skips IQC fetch and segments', (tester) async {
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
    expect(_segmentText('自制产成品'), findsOneWidget);
    // 「全部待检单」不挂徽章；自制产成品徽章 1。
    expect(_segmentBadge('1'), findsOneWidget);
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
    'segment bar matches the stadium search height and shows no check',
    (tester) async {
      await _pumpPage(
        tester,
        api: _FqcApi(),
        iqc: _FakeIqcRepository(),
        permissions: _bothViewPerms,
      );

      // 分类框高度对齐搜索框（同一工具条并排视觉一致）。
      final segmentHeight = tester
          .getSize(find.byType(SegmentedButton<String>))
          .height;
      final searchHeight = tester.getSize(find.byType(TextField)).height;
      expect(segmentHeight, closeTo(searchHeight, 0.5));

      // 选中分段只变背景色，不出现 ✓ 图标。
      await tester.tap(_segmentText('自制产成品'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(SegmentedButton<String>),
          matching: find.byIcon(Icons.check),
        ),
        findsNothing,
      );
    },
  );
}

class _FakeIqcRepository implements ProcurementInspectionRepository {
  final List<PendingInspectionReceipt> receipts = const [
    PendingInspectionReceipt(
      receiptType: 'PURCHASE',
      receiptId: 'receipt-1',
      billNo: 'CJ20260822000001',
      supplierName: '采购供应商',
      itemCount: 1,
      pendingBaseQty: 5,
    ),
    PendingInspectionReceipt(
      receiptType: 'SUBCONTRACT',
      receiptId: 'receipt-2',
      billNo: 'WT20260823000002',
      supplierName: '委外加工商',
      itemCount: 1,
      pendingBaseQty: 3,
    ),
  ];

  int pendingReceiptsCalls = 0;

  @override
  Future<int> pendingCount() async => receipts.length;

  @override
  Future<List<PendingInspectionReceipt>> pendingReceipts() async {
    pendingReceiptsCalls++;
    return receipts;
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
}

class _FqcApi extends ApiClient {
  _FqcApi({this.withSheet = false}) : super(Dio());

  /// true = 待检任务归属一张品质检查单（V547），队列显示检查单行而非任务行。
  final bool withSheet;
  int sheetDetailCalls = 0;

  Map<String, dynamic>? decisionBody;
  Map<String, dynamic>? batchBody;
  bool decided = false;
  int listCalls = 0;
  int capabilityCalls = 0;

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
      return {
        'sheet': _sheet,
        'inspections': [decided ? _decidedInspection : _sheetInspection],
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
