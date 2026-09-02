import 'dart:io';

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

  test('confirm payload trims place and carries no commercial fields', () {
    const command = WarehouseIqcStockInConfirmCommand(
      idempotencyKey: 'warehouse-key-1',
      items: [
        WarehouseIqcStockInConfirmItem(
          passEventId: 'pass-1',
          baseQty: 3.5,
          expectedRemainingBaseQty: 5,
          place: ' B-02 ',
        ),
      ],
    );
    expect(command.toJson()['items'], [
      {
        'passEventId': 'pass-1',
        'baseQty': 3.5,
        'expectedRemainingBaseQty': 5.0,
        'place': 'B-02',
      },
    ]);
    expect(
      warehouseIqcStockInForbiddenKeys,
      containsAll({'price', 'amount', 'currencyCode', 'exchangeRate'}),
    );
  });

  test('detail route, merged badge and warehouse-wide refresh stay wired', () {
    final hub = File(
      'lib/features/warehouse/pages/warehouse_hub_page.dart',
    ).readAsStringSync();
    final moduleBadge = File(
      'lib/features/dashboard/widgets/module_badge_sum.dart',
    ).readAsStringSync();
    final globalRefresh = File(
      'lib/features/dashboard/providers/workbench_refresh.dart',
    ).readAsStringSync();
    final router = File('lib/core/router/app_router.dart').readAsStringSync();

    // 2026-09-01 合并后：hub 卡改挂「品质部检查结果」徽章，旧列表路由重定向保链；
    // 旧详情页已删除，深链重定向到合并页详情（同参）。
    expect(hub, contains('WarehouseQualityResultBadge'));
    expect(hub, contains('RouteName.warehouseQualityResults'));
    // hub 的计数失效统一走 invalidateWarehouseTaskCounts（2026-09-01 下午起），
    // 品质结果的 未完结总数 + 父分类（来源）分段计数 都在其中失效。
    final countRefresh = File(
      'lib/features/warehouse/providers/warehouse_count_refresh.dart',
    ).readAsStringSync();
    expect(hub, contains('invalidateWarehouseTaskCounts'));
    expect(
      countRefresh,
      contains('warehouseQualityResultPendingCountProvider'),
    );
    expect(countRefresh, contains('warehouseQualityResultTypeCountsProvider'));
    expect(moduleBadge, contains('warehouseQualityResultPendingCountProvider'));
    expect(
      globalRefresh,
      contains('warehouseQualityResultPendingCountProvider'),
    );
    expect(
      moduleBadge,
      isNot(contains('warehouseIqcStockInPendingCountProvider')),
    );
    expect(
      globalRefresh,
      isNot(contains('warehouseIqcStockInPendingCountProvider')),
    );
    expect(router, contains("name: 'warehouse-iqc-stock-ins'"));
    expect(router, contains("name: 'warehouse-iqc-stock-in-detail'"));
    expect(router, contains("name: 'warehouse-quality-results'"));
    expect(router, contains('RouteName.warehouseQualityResults'));
    // 旧 IQC 待入库/退回详情页源码已删除，只剩重定向保链。
    expect(
      File(
        'lib/features/warehouse/pages/warehouse_iqc_stock_in_detail_page.dart',
      ).existsSync(),
      isFalse,
    );
    expect(
      File(
        'lib/features/warehouse/pages/warehouse_iqc_return_detail_page.dart',
      ).existsSync(),
      isFalse,
    );
  });

  testWidgets(
    'merged quality-result list exposes status columns and batch entry only',
    (tester) async {
      _viewport(tester, const Size(375, 900));
      final gateway = _QualityGateway();
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        _qualityApp(const WarehouseQualityResultsPage(), gateway, preferences),
      );
      await tester.pumpAndSettle();

      final table = tester
          .widget<MasterDataTableView<WarehouseQualityResultTask>>(
            find.byKey(const Key('warehouse-quality-result-table')),
          );
      final columnKeys = {for (final column in table.columns) column.key};
      expect(
        columnKeys,
        containsAll({
          'workStatus',
          'billNo',
          'supplierName',
          'warehouseName',
          'pendingSliceCount',
          'pendingReturnCount',
        }),
      );
      expect(
        columnKeys.intersection(warehouseIqcStockInForbiddenKeys),
        isEmpty,
      );
      expect(find.text('等待检查结果'), findsWidgets);
      expect(find.text('等待结果'), findsWidgets);
      expect(find.text('999999.99'), findsNothing);
      expect(find.text('USD-SECRET'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _qualityApp(
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

class _QualityGateway implements WarehouseQualityResultGateway {
  @override
  Future<PagedResult<WarehouseQualityResultTask>> list({
    int page = 1,
    int size = 40,
    WarehouseIqcStockInReceiptType? receiptType,
    WarehouseQualityWorkStatus? workStatus,
    String? keyword,
  }) async => PagedResult(
    items: [WarehouseQualityResultTask.fromJson(_qualitySummaryJson)],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<Map<WarehouseQualityWorkStatus, int>> statusCounts({
    WarehouseIqcStockInReceiptType? receiptType,
    String? keyword,
  }) async => const {
    WarehouseQualityWorkStatus.waitingInspection: 1,
    WarehouseQualityWorkStatus.allPassed: 0,
    WarehouseQualityWorkStatus.partialPassed: 0,
    WarehouseQualityWorkStatus.returnRequired: 0,
    WarehouseQualityWorkStatus.completed: 0,
  };

  @override
  Future<int> pendingCount() async => 1;

  @override
  Future<Map<WarehouseIqcStockInReceiptType, int>> typeCounts() async => const {
    WarehouseIqcStockInReceiptType.purchase: 1,
    WarehouseIqcStockInReceiptType.subcontract: 0,
  };

  @override
  Future<WarehouseQualityResultDetail> detail(
    String receiptType,
    String receiptId,
  ) async => WarehouseQualityResultDetail.fromJson(_qualityDetailJson);

  @override
  Future<WarehouseQualityBatchConfirmResult> batchConfirm(
    WarehouseQualityBatchConfirmCommand command,
  ) async => const WarehouseQualityBatchConfirmResult(
    confirmedReceipts: 1,
    confirmedItemCount: 1,
    results: [],
  );
}

/// 兜底网关：列表页误触单张确认接口时让测试失败（批量必须走批量接口）。
class _FailingGateway implements WarehouseIqcStockInGateway {
  @override
  Future<WarehouseIqcStockInConfirmResult> confirm(
    String receiptType,
    String receiptId,
    WarehouseIqcStockInConfirmCommand command,
  ) async => throw StateError('unexpected single confirm');
}

const Map<String, dynamic> _qualitySummaryJson = {
  'receiptType': 'PURCHASE',
  'receiptId': 'receipt-1',
  'billNo': 'PR-001',
  'billDate': '2026-08-31',
  'supplierId': 'supplier-1',
  'supplierName': '示例供应商',
  'warehouseId': 'warehouse-1',
  'warehouseName': '原料仓',
  'workStatus': 'WAITING_INSPECTION',
  'goodsLineCount': 1,
  'passedLineCount': 0,
  'failedLineCount': 0,
  'openItemCount': 1,
  'pendingSliceCount': 0,
  'pendingReturnCount': 0,
  'lastActivityAt': '2026-08-31T09:00:00Z',
};

Map<String, dynamic> get _qualityDetailJson => {
  ..._qualitySummaryJson,
  'qualityStatus': 'IN_PROGRESS',
  'completed': false,
  'containsOwnRelease': false,
  'allowedActions': <String>[],
  'items': <Map<String, dynamic>>[],
  'history': <Map<String, dynamic>>[],
  'rejections': <Map<String, dynamic>>[],
};

void _viewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
