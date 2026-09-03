import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_stock_in.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_quality_result.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_sales_outbound.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_result_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_iqc_stock_in_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_quality_result_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_sales_outbound_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

/// 可编辑表格控制器的偏好持久化需要 SharedPreferences（测试统一 mock）。
late final SharedPreferences _sharedPrefs;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _sharedPrefs = await SharedPreferences.getInstance();
  });

  testWidgets('sales list at 375px contains warehouse columns only', (
    tester,
  ) async {
    _viewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(_sharedPrefs),
          warehouseSalesOutboundRepositoryProvider.overrideWithValue(
            _SalesGateway(),
          ),
        ],
        child: const MaterialApp(home: WarehouseSalesOutboundPage()),
      ),
    );
    await tester.pumpAndSettle();
    // 2026-09-03 分类范式：状态行默认不选（未选不发请求），
    // 先选「待拣货」段再断言表格列。
    await tester.tap(find.text('待拣货').last);
    await tester.pumpAndSettle();

    final table = tester
        .widget<MasterDataTableView<WarehouseSalesOutboundSummary>>(
          find.byKey(const Key('warehouse-sales-outbound-table')),
        );
    final keys = {for (final column in table.columns) column.key};
    expect(keys, containsAll(<String>{'billNo', 'warehouseWorkStatus'}));
    expect(keys.any(_commercialKey), isFalse);
    _expectNoCommercialText();
    expect(tester.takeException(), isNull);
  });

  testWidgets('sales detail shows physical lines and server-allowed actions', (
    tester,
  ) async {
    _viewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(_sharedPrefs),
          warehouseSalesOutboundRepositoryProvider.overrideWithValue(
            _SalesGateway(),
          ),
        ],
        child: const MaterialApp(
          home: WarehouseSalesOutboundDetailPage(id: 'sales-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('当前建议库位'), findsOneWidget);
    expect(find.text('A01-01'), findsWidgets);
    expect(
      find.byKey(const Key('warehouse-sales-outbound-action-PICKING')),
      findsOneWidget,
    );
    _expectNoCommercialText();
    expect(tester.takeException(), isNull);
  });

  testWidgets('quality detail exposes physical return facts only', (
    tester,
  ) async {
    _viewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(_sharedPrefs),
          warehouseQualityResultRepositoryProvider.overrideWithValue(
            _QualityGateway(),
          ),
          warehouseIqcStockInRepositoryProvider.overrideWithValue(
            _FailingStockInGateway(),
          ),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.procurementIqcRejectionRecordReturn,
          }),
        ],
        child: const MaterialApp(
          home: WarehouseQualityResultDetailPage(
            receiptType: 'PURCHASE',
            receiptId: 'receipt-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 不合格退回案件在合并详情页内展示物理事实（货品/拒收数量/登记入口）。
    expect(find.textContaining('拒收产品'), findsWidgets);
    expect(find.textContaining('不合格 2 件'), findsOneWidget);
    expect(find.text('登记退回'), findsOneWidget);
    // 只读权限（无入库确认双权限）：不出确认底栏，明细表不渲染输入单元。
    expect(
      find.byKey(const Key('warehouse-quality-detail-confirm')),
      findsNothing,
    );
    _expectNoCommercialText();
    expect(tester.takeException(), isNull);
  });
}

void _expectNoCommercialText() {
  for (final text in const [
    '999999.99',
    'USD-SECRET',
    'CREDIT-SECRET',
    '单价',
    '金额',
    '币种',
    '税率',
    '贷项',
    '抵销',
  ]) {
    expect(find.textContaining(text), findsNothing);
  }
}

bool _commercialKey(String key) {
  final value = key.toLowerCase();
  return value.contains('price') ||
      value.contains('amount') ||
      value.contains('currency') ||
      value.contains('tax') ||
      value.contains('settlement') ||
      value.contains('credit') ||
      value.contains('offset');
}

void _viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(375, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _SalesGateway implements WarehouseSalesOutboundGateway {
  @override
  Future<int> pendingCount() async => 0;

  @override
  Future<PagedResult<WarehouseSalesOutboundSummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? warehouseWorkStatus,
    String? dateFrom,
    String? dateTo,
  }) async => PagedResult(
    items: [_salesDetail.header],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<WarehouseSalesOutboundDetail> detail(String id) async => _salesDetail;

  @override
  Future<WarehouseSalesOutboundDetail> transition(
    String id, {
    required String targetStatus,
    String? reason,
  }) async => _salesDetail;
}

class _QualityGateway implements WarehouseQualityResultGateway {
  @override
  Future<WarehouseQualityResultDetail> detail(
    String receiptType,
    String receiptId,
  ) async => WarehouseQualityResultDetail.fromJson(_qualityDetailJson);

  @override
  Future<Map<WarehouseQualityWorkStatus, int>> statusCounts({
    WarehouseIqcStockInReceiptType? receiptType,
    String? keyword,
  }) async => throw StateError('unexpected status counts');

  @override
  Future<int> pendingCount() async => 1;

  @override
  Future<Map<WarehouseIqcStockInReceiptType, int>> typeCounts() async =>
      throw StateError('unexpected type counts');

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

/// 兜底：只读权限场景不得触发单张确认。
class _FailingStockInGateway implements WarehouseIqcStockInGateway {
  @override
  Future<WarehouseIqcStockInConfirmResult> confirm(
    String receiptType,
    String receiptId,
    WarehouseIqcStockInConfirmCommand command,
  ) async => throw StateError('unexpected single confirm');
}

final WarehouseSalesOutboundDetail _salesDetail =
    WarehouseSalesOutboundDetail.fromJson(<String, dynamic>{
      'id': 'sales-1',
      'billNo': 'XS-001',
      'billDate': '2026-08-31',
      'clientName': '示例客户',
      'warehouseName': '成品仓',
      'warehouseWorkStatus': 'PENDING_PICK',
      'allowedWarehouseTargets': ['PICKING', 'EXCEPTION'],
      'totalLocal': '999999.99',
      'currencyCode': 'USD-SECRET',
      'lines': [
        {
          'id': 'line-1',
          'goodsCode': 'G-001',
          'goodsName': '实物产品',
          'currentStockPlaceHint': 'A01-01',
          'unitName': '件',
          'quantity': '10.0000',
          'unitPrice': '100.00',
        },
      ],
    });

/// 合并详情（含不合格退回案件）；注入商业字段证明解析端永不回显。
final Map<String, dynamic> _qualityDetailJson = <String, dynamic>{
  'workStatus': 'RETURN_REQUIRED',
  'receiptType': 'PURCHASE',
  'receiptId': 'receipt-1',
  'billNo': 'PR-001',
  'billDate': '2026-08-31',
  'supplierId': 'supplier-1',
  'supplierName': '示例供应商',
  'warehouseId': 'warehouse-1',
  'warehouseName': '一号仓',
  'qualityStatus': 'RESOLVED',
  'goodsLineCount': 1,
  'passedLineCount': 0,
  'failedLineCount': 1,
  'openItemCount': 0,
  'pendingSliceCount': 0,
  'pendingReturnCount': 1,
  'completed': false,
  'containsOwnRelease': false,
  'allowedActions': <String>[],
  'lines': <Map<String, dynamic>>[
    {
      'inspectionItemId': 'inspection-1',
      'goodsId': 'goods-1',
      'goodsCode': 'G-001',
      'goodsName': '拒收产品',
      'unitName': '件',
      'lineStatus': 'RESOLVED',
      'receivedBaseQty': 2,
      'passedBaseQty': 0,
      'failedBaseQty': 2,
      'warehouseStockedBaseQty': 0,
      'pendingStockBaseQty': 0,
      'failedAmountLocal': '999999.99',
      'currencyCode': 'USD-SECRET',
    },
  ],
  'items': <Map<String, dynamic>>[],
  'history': <Map<String, dynamic>>[],
  'rejections': <Map<String, dynamic>>[
    {
      'id': 'rejection-1',
      'inspectionItemId': 'inspection-1',
      'goodsId': 'goods-1',
      'goodsCode': 'G-001',
      'goodsName': '拒收产品',
      'unitName': '件',
      'failedQty': 2,
      'physicalStatus': 'PENDING_RETURN',
      'rowVersion': 3,
      'canRecordReturn': true,
      'failedAmountLocal': '999999.99',
      'currencyCode': 'USD-SECRET',
      'creditReference': 'CREDIT-SECRET',
    },
  ],
};
