import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_return.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_stock_in.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_quality_result.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_pre_stock_in_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_result_detail_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_iqc_return_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_iqc_stock_in_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_quality_result_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

// 先入库后质检(V596 / ADR-090)前端契约：
// - 模型：任务行/详情/明细行/退回案件/入库历史带上架位置与来源；
// - 上架页：只列等结论且未上架的行，库位必填，提交按行落上架仓+库位；
// - 详情页：已上架横幅 + 「先入库上架」按钮跟着服务端动作码走；
// - 到货登记结果：STOCKED_PENDING_INSPECTION 解析为已上架待检。

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('models parse pre-stock location, counts, origin and gates', () {
    final task = WarehouseQualityResultTask.fromJson({
      ..._summaryJson('WAITING_INSPECTION', openItemCount: 3),
      'preStockedLineCount': 2,
    });
    expect(task.preStockedLineCount, 2);
    expect(task.hasPreStockableLines, isTrue);
    expect(task.workStatusLabel, '等待检查结果 · 已上架 2 行');
    final fullyShelved = WarehouseQualityResultTask.fromJson({
      ..._summaryJson('WAITING_INSPECTION', openItemCount: 2),
      'preStockedLineCount': 2,
    });
    expect(fullyShelved.hasPreStockableLines, isFalse);
    expect(
      WarehouseQualityResultTask.fromJson(
        _summaryJson('ALL_PASSED'),
      ).workStatusLabel,
      '全部合格 · 待入库',
    );

    final detail = WarehouseQualityResultDetail.fromJson(_detailJson());
    expect(detail.preStockedLineCount, 1);
    expect(detail.canPreStockIn, isTrue);
    expect(detail.preStockableLines.map((line) => line.inspectionItemId), [
      'inspection-pending',
    ]);
    final shelved = detail.lines.firstWhere(
      (line) => line.inspectionItemId == 'inspection-shelved',
    );
    expect(shelved.preStocked?.label, '原料仓 / A-01');
    expect(shelved.preStockable, isFalse);
    final pending = detail.lines.firstWhere(
      (line) => line.inspectionItemId == 'inspection-pending',
    );
    expect(pending.preStocked, isNull);
    expect(pending.placeHint, 'C-07');
    expect(pending.preStockable, isTrue);
    expect(detail.rejections.single.preStocked?.place, 'A-01');
    expect(detail.history.single.isAutoFromPreStock, isTrue);
    expect(detail.history.single.originLabel, '先入库后检 · 合格自动转正');

    // 服务端不给动作码时前端不得自作主张。
    final noAction = WarehouseQualityResultDetail.fromJson({
      ..._detailJson(),
      'allowedActions': <String>[],
    });
    expect(noAction.canPreStockIn, isFalse);

    expect(
      WarehouseArrivalRegistrationOutcome.fromName('STOCKED_PENDING_INSPECTION'),
      WarehouseArrivalRegistrationOutcome.stockedPendingInspection,
    );
    const batch = WarehouseArrivalRegistrationBatch(
      registrations: [
        WarehouseArrivalRegistration(
          outcome: WarehouseArrivalRegistrationOutcome.stockedPendingInspection,
          receiptBillNo: 'PR-1',
        ),
        WarehouseArrivalRegistration(
          outcome: WarehouseArrivalRegistrationOutcome.submittedForInspection,
          receiptBillNo: 'PR-2',
        ),
      ],
    );
    expect(batch.preStockedCount, 1);
    expect(batch.hasQuarantined, isFalse);
    expect(
      const WarehouseIqcPreStockInItem(
        inspectionItemId: 'i-1',
        warehouseId: 'w-1',
        place: ' A-01 ',
      ).toJson(),
      {'inspectionItemId': 'i-1', 'warehouseId': 'w-1', 'place': 'A-01'},
    );
  });

  testWidgets('pre-stock page lists shelvable lines, requires a place and submits', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final stockIn = _StockInGateway();
    await tester.pumpWidget(
      await _app(
        const WarehouseQualityPreStockInPage(
          receiptType: 'PURCHASE',
          receiptId: 'receipt-1',
        ),
        quality: _QualityGateway(_detailJson()),
        stockIn: stockIn,
        permissions: const {
          Perm.warehouseIqcStockInView,
          Perm.warehouseIqcStockInBeforeInspection,
        },
      ),
    );
    await tester.pumpAndSettle();

    // 只有「等结论且未上架」的行出现：已上架行与已结案行不进表。
    expect(find.text('待检产品'), findsOneWidget);
    expect(find.text('已上架产品'), findsNothing);
    expect(find.text('已结案产品'), findsNothing);
    expect(find.byKey(const Key('warehouse-quality-pre-stock-notice')), findsOneWidget);
    // 建议库位预填、上架仓默认收货参考仓。
    final placeField = find.byKey(const ValueKey('pre-stock-place-inspection-pending'));
    expect(tester.widget<TextFormField>(placeField).controller!.text, 'C-07');
    expect(find.text('原料仓'), findsWidgets);

    // 清空库位后提交：页内报错、不发请求。
    await tester.enterText(placeField, '');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-quality-pre-stock-confirm')));
    await tester.pumpAndSettle();
    expect(stockIn.preStockCalls, 0);
    expect(find.byKey(const Key('warehouse-quality-pre-stock-error')), findsOneWidget);

    await tester.enterText(placeField, ' D-08 ');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-quality-pre-stock-confirm')));
    await tester.pumpAndSettle();
    expect(stockIn.preStockCalls, 1);
    expect(stockIn.lastPreStock!.items.single.inspectionItemId, 'inspection-pending');
    expect(stockIn.lastPreStock!.items.single.warehouseId, 'warehouse-1');
    expect(stockIn.lastPreStock!.items.single.place, 'D-08');
    expect(find.byKey(const Key('warehouse-quality-pre-stock-error')), findsNothing);
  });

  testWidgets('without the independent authority the page is read-only', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      await _app(
        const WarehouseQualityPreStockInPage(
          receiptType: 'PURCHASE',
          receiptId: 'receipt-1',
        ),
        quality: _QualityGateway(_detailJson()),
        stockIn: _StockInGateway(),
        permissions: const {
          Perm.warehouseIqcStockInView,
          Perm.warehouseIqcStockInConfirm,
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('warehouse-quality-pre-stock-confirm')), findsNothing);
    expect(find.textContaining('没有「到货先入库后质检」权限'), findsOneWidget);
  });

  testWidgets('detail page shows shelved notice and the pre-stock action', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      await _app(
        const WarehouseQualityResultDetailPage(
          receiptType: 'PURCHASE',
          receiptId: 'receipt-1',
        ),
        quality: _QualityGateway(_detailJson()),
        stockIn: _StockInGateway(),
        permissions: const {
          Perm.warehouseIqcStockInView,
          Perm.warehouseIqcStockInBeforeInspection,
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('warehouse-quality-detail-pre-stocked')), findsOneWidget);
    expect(find.text('先入库上架(1)'), findsOneWidget);
    // 已上架行在合并表里显示上架库位；不合格退回卡片带实物位置。
    expect(find.text('已上架 · A-01'), findsOneWidget);
    expect(find.text('已上架 · A-02'), findsOneWidget);
    expect(find.textContaining('实物位置 原料仓 / A-01'), findsOneWidget);
    expect(find.textContaining('先入库后检 · 合格自动转正'), findsOneWidget);
  });
}

Future<Widget> _app(
  Widget page, {
  required WarehouseQualityResultGateway quality,
  required WarehouseIqcStockInGateway stockIn,
  required Set<String> permissions,
}) async {
  final preferences = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      warehouseQualityResultRepositoryProvider.overrideWithValue(quality),
      warehouseIqcStockInRepositoryProvider.overrideWithValue(stockIn),
      warehouseIqcReturnRepositoryProvider.overrideWithValue(
        _FailingReturnGateway(),
      ),
      sharedPreferencesProvider.overrideWithValue(preferences),
      currentPermissionsProvider.overrideWithValue(permissions),
      isSuperAdminProvider.overrideWithValue(false),
    ],
    // 带 GoRouter 壳：页面成功后走 context.canPop()/pop(go_router 扩展)，无路由会抛错。
    child: MaterialApp.router(
      routerConfig: GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => page)],
      ),
    ),
  );
}

class _QualityGateway implements WarehouseQualityResultGateway {
  _QualityGateway(this.detailJson);

  final Map<String, dynamic> detailJson;

  @override
  Future<WarehouseQualityResultDetail> detail(
    String receiptType,
    String receiptId,
  ) async => WarehouseQualityResultDetail.fromJson(detailJson);

  @override
  Future<int> pendingCount() async => 0;

  @override
  Future<Map<WarehouseIqcStockInReceiptType, int>> typeCounts() async => const {};

  @override
  Future<Map<WarehouseQualityWorkStatus, int>> statusCounts({
    WarehouseIqcStockInReceiptType? receiptType,
    String? keyword,
  }) async => const {};

  @override
  Future<WarehouseQualityBatchConfirmResult> batchConfirm(
    WarehouseQualityBatchConfirmCommand command,
  ) async => throw StateError('unexpected batch confirm');

  @override
  Future<PagedResult<WarehouseQualityResultTask>> list({
    int page = 1,
    int size = 40,
    WarehouseIqcStockInReceiptType? receiptType,
    WarehouseQualityWorkStatus? workStatus,
    String? keyword,
    String? dateFrom,
    String? dateTo,
  }) async => throw StateError('unexpected list');
}

class _StockInGateway implements WarehouseIqcStockInGateway {
  int preStockCalls = 0;
  WarehouseIqcPreStockInCommand? lastPreStock;

  @override
  Future<WarehouseIqcStockInConfirmResult> confirm(
    String receiptType,
    String receiptId,
    WarehouseIqcStockInConfirmCommand command,
  ) async => throw ApiException('CONFLICT', 'unexpected confirm');

  @override
  Future<WarehouseIqcPreStockInResult> preStockIn(
    String receiptType,
    String receiptId,
    WarehouseIqcPreStockInCommand command,
  ) async {
    preStockCalls++;
    lastPreStock = command;
    return WarehouseIqcPreStockInResult(
      requestedLineCount: command.items.length,
      stockedLineCount: command.items.length,
      replayedLineCount: 0,
      stockedAt: '2026-09-16T10:00:00Z',
    );
  }
}

class _FailingReturnGateway implements WarehouseIqcReturnGateway {
  @override
  Future<WarehouseIqcReturnTask> recordReturn(
    String rejectionId,
    WarehouseIqcRecordReturnCommand command,
  ) async => throw StateError('unexpected record return');
}

Map<String, dynamic> _summaryJson(String workStatus, {int openItemCount = 0}) => {
  'receiptType': 'PURCHASE',
  'receiptId': 'receipt-1',
  'billNo': 'PR-001',
  'billDate': '2026-09-16',
  'supplierId': 'supplier-1',
  'supplierName': '示例供应商',
  'warehouseId': 'warehouse-1',
  'warehouseName': '原料仓',
  'workStatus': workStatus,
  'goodsLineCount': 3,
  'passedLineCount': 0,
  'failedLineCount': 0,
  'openItemCount': openItemCount,
  'pendingSliceCount': 0,
  'pendingReturnCount': 0,
  'lastActivityAt': '2026-09-16T09:00:00Z',
};

Map<String, dynamic> _detailJson() => {
  'workStatus': 'WAITING_INSPECTION',
  'receiptType': 'PURCHASE',
  'receiptId': 'receipt-1',
  'billNo': 'PR-001',
  'billDate': '2026-09-16',
  'supplierId': 'supplier-1',
  'supplierName': '示例供应商',
  'warehouseId': 'warehouse-1',
  'warehouseName': '原料仓',
  'qualityStatus': 'IN_PROGRESS',
  'goodsLineCount': 3,
  'passedLineCount': 1,
  'failedLineCount': 1,
  'openItemCount': 2,
  'pendingSliceCount': 0,
  'pendingReturnCount': 1,
  'preStockedLineCount': 1,
  'completed': false,
  'containsOwnRelease': false,
  'allowedActions': <String>['PRE_STOCK_IN'],
  'lines': [
    {
      'inspectionItemId': 'inspection-shelved',
      'goodsId': 'goods-1',
      'goodsCode': 'G-001',
      'goodsName': '已上架产品',
      'unitId': 'unit-1',
      'unitName': '件',
      'warehouseId': 'warehouse-1',
      'warehouseName': '原料仓',
      'lineStatus': 'PENDING',
      'receivedBaseQty': 10,
      'passedBaseQty': 0,
      'failedBaseQty': 0,
      'warehouseStockedBaseQty': 0,
      'pendingStockBaseQty': 0,
      'preStocked': {
        'warehouseId': 'warehouse-1',
        'warehouseName': '原料仓',
        'place': 'A-01',
        'stockedAt': '2026-09-16T08:00:00Z',
        'stockedByName': '仓管甲',
      },
      'placeHint': 'A-01',
    },
    {
      'inspectionItemId': 'inspection-pending',
      'goodsId': 'goods-2',
      'goodsCode': 'G-002',
      'goodsName': '待检产品',
      'unitId': 'unit-1',
      'unitName': '件',
      'warehouseId': 'warehouse-1',
      'warehouseName': '原料仓',
      'lineStatus': 'PENDING',
      'receivedBaseQty': 5,
      'passedBaseQty': 0,
      'failedBaseQty': 0,
      'warehouseStockedBaseQty': 0,
      'pendingStockBaseQty': 0,
      'preStocked': null,
      'placeHint': 'C-07',
    },
    {
      'inspectionItemId': 'inspection-resolved',
      'goodsId': 'goods-3',
      'goodsCode': 'G-003',
      'goodsName': '已结案产品',
      'unitId': 'unit-1',
      'unitName': '件',
      'warehouseId': 'warehouse-1',
      'warehouseName': '原料仓',
      'lineStatus': 'RESOLVED',
      'receivedBaseQty': 4,
      'passedBaseQty': 3,
      'failedBaseQty': 1,
      'warehouseStockedBaseQty': 3,
      'pendingStockBaseQty': 0,
      'preStocked': {
        'warehouseId': 'warehouse-1',
        'warehouseName': '原料仓',
        'place': 'A-02',
      },
    },
  ],
  'items': <Map<String, dynamic>>[],
  'history': [
    {
      'stockInItemId': 'stock-1',
      'batchId': 'batch-1',
      'passEventId': 'pass-1',
      'goodsId': 'goods-3',
      'goodsCode': 'G-003',
      'goodsName': '已结案产品',
      'unitName': '件',
      'baseQty': 3,
      'place': 'A-01',
      'confirmedBy': '品检乙',
      'confirmedAt': '2026-09-16T09:30:00Z',
      'warehouseId': 'warehouse-1',
      'warehouseName': '原料仓',
      'origin': 'PRE_STOCKED_AUTO',
    },
  ],
  'rejections': [
    {
      'id': 'rejection-1',
      'inspectionItemId': 'inspection-resolved',
      'goodsId': 'goods-3',
      'goodsCode': 'G-003',
      'goodsName': '已结案产品',
      'unitName': '件',
      'failedQty': 1,
      'physicalStatus': 'PENDING_RETURN',
      'rowVersion': 1,
      'canRecordReturn': false,
      'preStocked': {
        'warehouseId': 'warehouse-1',
        'warehouseName': '原料仓',
        'place': 'A-01',
      },
    },
  ],
};
