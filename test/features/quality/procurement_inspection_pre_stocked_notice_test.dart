import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/quality/pages/quality_pending_disposal_page.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inspection_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

// 先入库后质检(V596)：品质部单据处置页顶部标红「货品已入库，需到对应储放区域检查」，
// 明细「储放位置」列逐行给出仓库/库位；未上架的单没有横幅。

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('pending receipt and item parse the pre-stock location', () {
    final receipt = PendingInspectionReceipt.fromJson(const {
      'receiptType': 'PURCHASE',
      'receiptId': 'receipt-1',
      'itemCount': 2,
      'preStockedItemCount': 1,
    });
    expect(receipt.hasPreStockedItems, isTrue);
    final item = ProcurementInspectionItem.fromJson(const {
      'id': 'inspection-1',
      'goodsName': '待检件',
      'preStocked': {
        'warehouseId': 'warehouse-1',
        'warehouseName': '五金仓',
        'place': 'B-12',
      },
    });
    expect(item.preStocked?.label, '五金仓 / B-12');
    expect(
      ProcurementInspectionItem.fromJson(const {'id': 'x'}).preStocked,
      isNull,
    );
  });

  testWidgets('shelved receipt shows the red notice and per-line location', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          procurementInspectionRepositoryProvider.overrideWithValue(
            _ShelvedRepository(),
          ),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.procurementInspectionView,
            Perm.procurementInspectionHandle,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          home: ProcurementInspectionDetailPage(
            receiptType: 'PURCHASE',
            receiptId: 'receipt-1',
            extra: PendingInspectionReceipt(
              receiptType: 'PURCHASE',
              receiptId: 'receipt-1',
              billNo: 'CJ20260916000001',
              supplierName: '示例供应商',
              itemCount: 2,
              preStockedItemCount: 1,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('iqc-pre-stocked-notice')), findsOneWidget);
    expect(find.text('货品已入库，需到对应储放区域检查'), findsOneWidget);
    expect(find.textContaining('已上架件 → 五金仓 / B-12'), findsOneWidget);
    expect(find.text('已入库 · 五金仓 / B-12'), findsOneWidget);
    expect(find.text('待检区'), findsOneWidget);
  });
}

class _ShelvedRepository implements ProcurementInspectionRepository {
  @override
  Future<int> pendingCount() async => 1;

  @override
  Future<List<PendingInspectionReceipt>> pendingReceipts() async => const [];

  @override
  Future<List<ProcurementInspectionItem>> items(
    String receiptType,
    String receiptId,
  ) async => const [
    ProcurementInspectionItem(
      id: 'inspection-1',
      goodsId: 'goods-1',
      goodsCode: 'G-001',
      goodsName: '已上架件',
      baseUnitId: 'unit-1',
      baseUnitName: '个',
      receivedBaseQty: 10,
      passedBaseQty: 0,
      failedBaseQty: 0,
      remainingBaseQty: 10,
      status: 'PENDING',
      preStocked: WarehousePreStockedLocation(
        warehouseId: 'warehouse-1',
        warehouseName: '五金仓',
        place: 'B-12',
      ),
    ),
    ProcurementInspectionItem(
      id: 'inspection-2',
      goodsId: 'goods-2',
      goodsCode: 'G-002',
      goodsName: '待检区件',
      baseUnitId: 'unit-1',
      baseUnitName: '个',
      receivedBaseQty: 4,
      passedBaseQty: 0,
      failedBaseQty: 0,
      remainingBaseQty: 4,
      status: 'PENDING',
    ),
  ];

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
