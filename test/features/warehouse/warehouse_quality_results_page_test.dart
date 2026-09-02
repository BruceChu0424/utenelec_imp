import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_stock_in.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_quality_result.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_results_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_iqc_stock_in_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_quality_result_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('work status parses, labels and stays amount-free', () {
    final task = WarehouseQualityResultTask.fromJson(
      _summaryJson('ALL_PASSED', pendingSliceCount: 2, passedLineCount: 3),
    );
    expect(task.workStatus, WarehouseQualityWorkStatus.allPassed);
    expect(task.workStatus.label, '全部合格 · 待入库');
    expect(task.workStatus.actionable, isTrue);
    expect(task.verdictLabel, contains('合格 3'));

    final waiting = WarehouseQualityResultTask.fromJson(
      _summaryJson('WAITING_INSPECTION', openItemCount: 2),
    );
    expect(waiting.workStatus.actionable, isFalse);

    // 未知状态 fail-closed 到已完结（不产生可办任务）。
    final unknown = WarehouseQualityResultTask.fromJson(
      _summaryJson('FUTURE_STATUS'),
    );
    expect(unknown.workStatus, WarehouseQualityWorkStatus.completed);

    const command = WarehouseQualityBatchConfirmCommand(
      batches: [
        WarehouseQualityBatchConfirmEntry(
          receiptType: 'PURCHASE',
          receiptId: 'receipt-1',
          idempotencyKey: 'batch-key-0001',
          items: [
            WarehouseIqcStockInConfirmItem(
              passEventId: 'pass-1',
              baseQty: 5,
              expectedRemainingBaseQty: 5,
              place: ' B-02 ',
            ),
          ],
        ),
      ],
    );
    expect(command.toJson()['batches'], [
      {
        'receiptType': 'PURCHASE',
        'receiptId': 'receipt-1',
        'idempotencyKey': 'batch-key-0001',
        'items': [
          {
            'passEventId': 'pass-1',
            'baseQty': 5,
            'expectedRemainingBaseQty': 5.0,
            'place': 'B-02',
          },
        ],
      },
    ]);
    expect(
      WarehouseQualityBatchConfirmResult.fromJson(const {
        'confirmedReceipts': 2,
        'confirmedItemCount': 3,
        'results': [
          {
            'receiptType': 'PURCHASE',
            'receiptId': 'r-1',
            'batchId': 'b-1',
            'replayed': false,
            'confirmedCount': 2,
          },
        ],
      }).confirmedItemCount,
      3,
    );
  });

  testWidgets(
    'list renders status segments, row colors and stays commercial-free',
    (tester) async {
      _viewport(tester, const Size(1200, 900));
      final gateway = _QualityGateway([
        WarehouseQualityResultTask.fromJson(
          _summaryJson('ALL_PASSED', pendingSliceCount: 1, passedLineCount: 2),
        ),
      ]);
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        _app(const WarehouseQualityResultsPage(), gateway, preferences),
      );
      await tester.pumpAndSettle();

      final table = tester
          .widget<MasterDataTableView<WarehouseQualityResultTask>>(
            find.byKey(const Key('warehouse-quality-result-table')),
          );
      final columnKeys = {for (final column in table.columns) column.key};
      expect(columnKeys, containsAll({'workStatus', 'pendingSliceCount'}));
      expect(
        columnKeys.intersection(warehouseIqcStockInForbiddenKeys),
        isEmpty,
      );
      // 多选 + 行色接线：全绿行 tint 非空，选集由页面持有。
      expect(table.selectable, isTrue);
      expect(
        table.rowColor!(
          WarehouseQualityResultTask.fromJson(_summaryJson('ALL_PASSED')),
        ),
        isNotNull,
      );
      expect(find.text('全部合格 · 待入库'), findsWidgets);
      expect(find.text('等待结果'), findsWidgets);
      expect(
        find.byKey(const Key('warehouse-quality-result-batch-stock-in')),
        findsOneWidget,
      );
      expect(find.text('999999.99'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('multi-select batch stock-in submits grouped command', (
    tester,
  ) async {
    _viewport(tester, const Size(1200, 900));
    final gateway = _QualityGateway([
      WarehouseQualityResultTask.fromJson(
        _summaryJson('ALL_PASSED', pendingSliceCount: 1, passedLineCount: 1),
      ),
    ]);
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      _app(const WarehouseQualityResultsPage(), gateway, preferences),
    );
    await tester.pumpAndSettle();

    // 勾选行（表头三态全选 + 行勾选框；单行场景取最后一个）。
    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('warehouse-quality-result-batch-stock-in')),
    );
    await tester.pumpAndSettle();

    // 批量弹窗：改库位 + 改小数量（部分入库），提交。
    expect(find.textContaining('批量入库'), findsWidgets);
    await tester.enterText(
      find.byKey(const Key('quality-slice-qty-pass-1')),
      '3.5',
    );
    await tester.enterText(
      find.byKey(const Key('quality-slice-place-pass-1')),
      'B-02',
    );
    await tester.tap(find.byKey(const Key('warehouse-quality-batch-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认批量入库'));
    await tester.pumpAndSettle();

    final command = gateway.lastBatchCommand;
    expect(command, isNotNull);
    final entry = command!.batches.single;
    expect(entry.receiptType, 'PURCHASE');
    expect(entry.receiptId, 'receipt-1');
    expect(entry.items.single.baseQty, 3.5);
    expect(entry.items.single.expectedRemainingBaseQty, 5);
    expect(entry.items.single.place, 'B-02');
    expect(gateway.batchConfirmCalls, 1);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(
  Widget page,
  WarehouseQualityResultGateway gateway,
  SharedPreferences preferences, {
  Set<String> permissions = const {
    Perm.warehouseIqcStockInView,
    Perm.warehouseIqcStockInConfirm,
  },
}) {
  return ProviderScope(
    overrides: [
      warehouseQualityResultRepositoryProvider.overrideWithValue(gateway),
      warehouseIqcStockInRepositoryProvider.overrideWithValue(
        _FailingGateway(),
      ),
      sharedPreferencesProvider.overrideWithValue(preferences),
      currentPermissionsProvider.overrideWithValue(permissions),
      isSuperAdminProvider.overrideWithValue(false),
    ],
    child: MaterialApp(home: page),
  );
}

void _viewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _QualityGateway implements WarehouseQualityResultGateway {
  _QualityGateway(this.tasks);

  final List<WarehouseQualityResultTask> tasks;
  int batchConfirmCalls = 0;
  WarehouseQualityBatchConfirmCommand? lastBatchCommand;

  @override
  Future<PagedResult<WarehouseQualityResultTask>> list({
    int page = 1,
    int size = 40,
    WarehouseIqcStockInReceiptType? receiptType,
    WarehouseQualityWorkStatus? workStatus,
    String? keyword,
  }) async => PagedResult(
    items: tasks,
    page: page,
    size: size,
    total: tasks.length,
    totalPages: 1,
  );

  @override
  Future<Map<WarehouseQualityWorkStatus, int>> statusCounts({
    WarehouseIqcStockInReceiptType? receiptType,
    String? keyword,
  }) async => const {
    WarehouseQualityWorkStatus.waitingInspection: 0,
    WarehouseQualityWorkStatus.allPassed: 1,
    WarehouseQualityWorkStatus.partialPassed: 0,
    WarehouseQualityWorkStatus.returnRequired: 0,
    WarehouseQualityWorkStatus.completed: 0,
  };

  @override
  Future<int> pendingCount() async => tasks.length;

  @override
  Future<Map<WarehouseIqcStockInReceiptType, int>> typeCounts() async => {
    WarehouseIqcStockInReceiptType.purchase: 1,
    WarehouseIqcStockInReceiptType.subcontract: 0,
  };

  @override
  Future<WarehouseQualityResultDetail> detail(
    String receiptType,
    String receiptId,
  ) async => WarehouseQualityResultDetail.fromJson(_detailJson);

  @override
  Future<WarehouseQualityBatchConfirmResult> batchConfirm(
    WarehouseQualityBatchConfirmCommand command,
  ) async {
    batchConfirmCalls++;
    lastBatchCommand = command;
    return WarehouseQualityBatchConfirmResult(
      confirmedReceipts: 1,
      confirmedItemCount: command.batches.first.items.length,
      results: const [],
    );
  }
}

/// 兜底网关：合并页误触单张确认接口时让测试失败（批量必须走批量接口）。
class _FailingGateway implements WarehouseIqcStockInGateway {
  @override
  Future<WarehouseIqcStockInConfirmResult> confirm(
    String receiptType,
    String receiptId,
    WarehouseIqcStockInConfirmCommand command,
  ) async => throw StateError('unexpected single confirm');
}

Map<String, dynamic> _summaryJson(
  String workStatus, {
  int pendingSliceCount = 0,
  int pendingReturnCount = 0,
  int passedLineCount = 0,
  int failedLineCount = 0,
  int openItemCount = 0,
}) => {
  'receiptType': 'PURCHASE',
  'receiptId': 'receipt-1',
  'billNo': 'PR-001',
  'billDate': '2026-08-31',
  'supplierId': 'supplier-1',
  'supplierName': '示例供应商',
  'warehouseId': 'warehouse-1',
  'warehouseName': '原料仓',
  'workStatus': workStatus,
  'goodsLineCount': 2,
  'passedLineCount': passedLineCount,
  'failedLineCount': failedLineCount,
  'openItemCount': openItemCount,
  'pendingSliceCount': pendingSliceCount,
  'pendingReturnCount': pendingReturnCount,
  'lastActivityAt': '2026-08-31T09:00:00Z',
};

Map<String, dynamic> get _detailJson => {
  ..._summaryJson('ALL_PASSED', pendingSliceCount: 1, passedLineCount: 1),
  'qualityStatus': 'RESOLVED',
  'completed': false,
  'containsOwnRelease': false,
  'allowedActions': <String>['CONFIRM'],
  'items': [
    {
      'passEventId': 'pass-1',
      'inspectionItemId': 'inspection-1',
      'goodsId': 'goods-1',
      'goodsCode': 'G-001',
      'goodsName': '测试产品',
      'colorName': '黑色',
      'unitId': 'unit-1',
      'unitName': '件',
      'sourceOrderNo': 'PO-001',
      'receivedBaseQty': 10,
      'qualityPassedBaseQty': 5,
      'warehouseStockedBaseQty': 0,
      'releasedBaseQty': 5,
      'stockedForReleaseBaseQty': 0,
      'remainingBaseQty': 5,
      'releasedWeight': 2.5,
      'weightUnitId': 'kg',
      'weightUnitName': 'kg',
      'placeHint': 'A-01',
      'releaseNote': '抽检合格',
      'releasedBy': '品质员',
      'releasedAt': '2026-08-31T09:00:00Z',
    },
  ],
  'history': <Map<String, dynamic>>[],
  'rejections': <Map<String, dynamic>>[],
};
