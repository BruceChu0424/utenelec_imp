import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_stock_in.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_iqc_stock_in_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_iqc_stock_in_page.dart';
import 'package:uten_imp/features/warehouse/providers/warehouse_iqc_stock_in_count_provider.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_iqc_stock_in_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('model parses amount-free task and confirm payload', () {
    final summary = WarehouseIqcStockInTaskSummary.fromJson(_summaryJson);
    expect(summary.receiptType, WarehouseIqcStockInReceiptType.purchase);
    expect(summary.receiptId, 'receipt-1');
    expect(summary.pendingSliceCount, 1);
    expect(summary.statusLabel, contains('待仓库入库'));

    final detail = WarehouseIqcStockInTaskDetail.fromJson(
      _detailJson(remaining: 5),
    );
    expect(detail.canConfirm, isTrue);
    expect(detail.qualityStatusLabel, '品质检验进行中');
    expect(detail.items.single.placeHint, 'A-01');
    expect(detail.items.single.releasedWeight, 2.5);

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

  test(
    'unknown receipt type fails closed instead of defaulting to purchase',
    () {
      final json = Map<String, dynamic>.from(_summaryJson)
        ..['receiptType'] = 'FUTURE_RECEIPT_TYPE';

      expect(
        () => WarehouseIqcStockInTaskSummary.fromJson(json),
        throwsFormatException,
      );
    },
  );

  test(
    'count provider avoids the API without its exact view permission',
    () async {
      final gateway = _Gateway();
      final container = ProviderContainer(
        overrides: [
          warehouseIqcStockInRepositoryProvider.overrideWithValue(gateway),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.procurementInspectionView,
            Perm.procurementInspectionHandle,
            Perm.warehouseInboundStockIn,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      expect(
        await container.read(warehouseIqcStockInPendingCountProvider.future),
        0,
      );
      expect(gateway.pendingCountCalls, 0);
    },
  );

  test('queue route and badge participate in warehouse-wide refresh', () {
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

    expect(hub, contains('WarehouseIqcStockInBadge'));
    expect(hub, contains('Perm.warehouseIqcStockInView'));
    expect(hub, contains('warehouseIqcStockInPendingCountProvider'));
    expect(moduleBadge, contains('warehouseIqcStockInPendingCountProvider'));
    expect(globalRefresh, contains('warehouseIqcStockInPendingCountProvider'));
    expect(router, contains("name: 'warehouse-iqc-stock-ins'"));
    expect(router, contains("name: 'warehouse-iqc-stock-in-detail'"));
  });

  testWidgets('375px list exposes warehouse columns only', (tester) async {
    _viewport(tester, const Size(375, 900));
    final gateway = _Gateway();
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      _app(const WarehouseIqcStockInPage(), gateway, preferences),
    );
    await tester.pumpAndSettle();

    final table = tester
        .widget<MasterDataTableView<WarehouseIqcStockInTaskSummary>>(
          find.byKey(const Key('warehouse-iqc-stock-in-table')),
        );
    final columnKeys = {for (final column in table.columns) column.key};
    expect(
      columnKeys,
      containsAll({
        'status',
        'billNo',
        'supplierName',
        'warehouseName',
        'pendingSliceCount',
      }),
    );
    expect(columnKeys.intersection(warehouseIqcStockInForbiddenKeys), isEmpty);
    final rowMenu = table.rowMenuBuilder!(
      WarehouseIqcStockInTaskSummary.fromJson(_summaryJson),
    );
    expect(rowMenu.single, isA<UtenMenuItem>());
    expect((rowMenu.single as UtenMenuItem).label, '查看入库详情');
    expect(find.text('999999.99'), findsNothing);
    expect(find.text('USD-SECRET'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'confirm requires local view and confirm plus server allowed action',
    (tester) async {
      _viewport(tester, const Size(800, 900));
      final preferences = await SharedPreferences.getInstance();

      Future<void> verifyHidden({
        required Set<String> permissions,
        required bool serverAllowsConfirm,
      }) async {
        final gateway = _Gateway(serverAllowsConfirm: serverAllowsConfirm);
        await tester.pumpWidget(
          _app(
            const WarehouseIqcStockInDetailPage(
              receiptType: 'PURCHASE',
              receiptId: 'receipt-1',
            ),
            gateway,
            preferences,
            permissions: permissions,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('warehouse-iqc-stock-in-confirm')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('warehouse-iqc-stock-in-select-pass-1')),
          findsNothing,
        );
        if (permissions.contains(Perm.warehouseIqcStockInView) &&
            permissions.contains(Perm.warehouseIqcStockInConfirm) &&
            !serverAllowsConfirm) {
          expect(find.textContaining('职责分离'), findsOneWidget);
          expect(find.textContaining('另一名有权限的仓库人员'), findsOneWidget);
        }
        expect(gateway.confirmCalls, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }

      await verifyHidden(
        permissions: const {
          Perm.warehouseIqcStockInView,
          Perm.procurementInspectionHandle,
          Perm.warehouseInboundStockIn,
          Perm.stockDocEdit,
        },
        serverAllowsConfirm: true,
      );
      await verifyHidden(
        permissions: const {
          Perm.warehouseIqcStockInView,
          Perm.warehouseIqcStockInConfirm,
        },
        serverAllowsConfirm: false,
      );
      await verifyHidden(
        permissions: const {Perm.warehouseIqcStockInConfirm},
        serverAllowsConfirm: true,
      );
    },
  );

  testWidgets('partial confirm conflict refreshes facts and preserves input', (
    tester,
  ) async {
    _viewport(tester, const Size(1000, 1000));
    final gateway = _Gateway(conflictOnce: true);
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      _app(
        const WarehouseIqcStockInDetailPage(
          receiptType: 'PURCHASE',
          receiptId: 'receipt-1',
        ),
        gateway,
        preferences,
      ),
    );
    await tester.pumpAndSettle();

    const quantityKey = Key('warehouse-iqc-stock-in-qty-pass-1');
    const placeKey = Key('warehouse-iqc-stock-in-place-pass-1');
    await tester.enterText(find.byKey(quantityKey), '3.5');
    await tester.enterText(find.byKey(placeKey), 'B-02');
    await tester.tap(find.byKey(const Key('warehouse-iqc-stock-in-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认入库'));
    await tester.pumpAndSettle();

    expect(gateway.detailCalls, greaterThanOrEqualTo(2));
    expect(gateway.lastCommand?.items.single.baseQty, 3.5);
    expect(gateway.lastCommand?.items.single.expectedRemainingBaseQty, 5);
    expect(gateway.lastCommand?.items.single.place, 'B-02');
    expect(
      tester.widget<TextFormField>(find.byKey(quantityKey)).controller?.text,
      '3.5',
    );
    expect(
      tester.widget<TextFormField>(find.byKey(placeKey)).controller?.text,
      'B-02',
    );
    expect(find.textContaining('已保留当前输入'), findsOneWidget);
    expect(find.textContaining('刷新后的待入库余量 4'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed deep link keeps warehouse history read-only', (
    tester,
  ) async {
    _viewport(tester, const Size(800, 900));
    final gateway = _Gateway(completed: true);
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      _app(
        const WarehouseIqcStockInDetailPage(
          receiptType: 'PURCHASE',
          receiptId: 'receipt-1',
        ),
        gateway,
        preferences,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('warehouse-iqc-stock-in-completed')), findsOne);
    expect(find.text('当前合格切片已全部完成入库'), findsOneWidget);
    expect(find.textContaining('实际库位 C-03'), findsOneWidget);
    expect(find.textContaining('仓库员'), findsOneWidget);
    expect(
      find.byKey(const Key('warehouse-iqc-stock-in-confirm')),
      findsNothing,
    );
    expect(find.text('999999.99'), findsNothing);
    expect(find.text('USD-SECRET'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(
  Widget page,
  WarehouseIqcStockInGateway gateway,
  SharedPreferences preferences, {
  Set<String> permissions = const {
    Perm.warehouseIqcStockInView,
    Perm.warehouseIqcStockInConfirm,
  },
}) {
  return ProviderScope(
    overrides: [
      warehouseIqcStockInRepositoryProvider.overrideWithValue(gateway),
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

class _Gateway implements WarehouseIqcStockInGateway {
  _Gateway({
    this.conflictOnce = false,
    this.completed = false,
    this.serverAllowsConfirm = true,
  });

  final bool conflictOnce;
  final bool completed;
  final bool serverAllowsConfirm;
  int detailCalls = 0;
  int confirmCalls = 0;
  int pendingCountCalls = 0;
  WarehouseIqcStockInConfirmCommand? lastCommand;

  @override
  Future<PagedResult<WarehouseIqcStockInTaskSummary>> list({
    int page = 1,
    int size = 40,
    WarehouseIqcStockInReceiptType? receiptType,
    String? keyword,
  }) async => PagedResult(
    items: [WarehouseIqcStockInTaskSummary.fromJson(_summaryJson)],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<int> pendingCount() async {
    pendingCountCalls++;
    return completed ? 0 : 1;
  }

  @override
  Future<WarehouseIqcStockInTaskDetail> detail(
    String receiptType,
    String receiptId,
  ) async {
    detailCalls++;
    return WarehouseIqcStockInTaskDetail.fromJson(
      completed
          ? _completedDetailJson
          : _detailJson(
              remaining: detailCalls > 1 ? 4 : 5,
              serverAllowsConfirm: serverAllowsConfirm,
            ),
    );
  }

  @override
  Future<WarehouseIqcStockInConfirmResult> confirm(
    String receiptType,
    String receiptId,
    WarehouseIqcStockInConfirmCommand command,
  ) async {
    confirmCalls++;
    lastCommand = command;
    if (conflictOnce && confirmCalls == 1) {
      throw ApiException('CONFLICT', '品质放行待入库余量已变化');
    }
    return const WarehouseIqcStockInConfirmResult(
      batchId: 'batch-1',
      replayed: false,
      confirmedCount: 1,
      confirmedAt: '2026-08-31T10:30:00Z',
    );
  }
}

const Map<String, dynamic> _summaryJson = {
  'receiptType': 'PURCHASE',
  'receiptId': 'receipt-1',
  'billNo': 'PR-001',
  'billDate': '2026-08-31',
  'supplierId': 'supplier-1',
  'supplierName': '示例供应商',
  'warehouseId': 'warehouse-1',
  'warehouseName': '原料仓',
  'goodsLineCount': 1,
  'pendingSliceCount': 1,
  'firstReleasedAt': '2026-08-31T09:00:00Z',
  'lastReleasedAt': '2026-08-31T09:00:00Z',
  'status': 'PENDING_STOCK_IN',
};

Map<String, dynamic> _detailJson({
  required num remaining,
  bool serverAllowsConfirm = true,
}) => {
  ..._summaryJson,
  'qualityStatus': 'IN_PROGRESS',
  'pendingSliceCount': 1,
  'completed': false,
  'allowedActions': serverAllowsConfirm ? ['CONFIRM'] : <String>[],
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
      'remainingBaseQty': remaining,
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
};

final Map<String, dynamic> _completedDetailJson = {
  ..._summaryJson,
  'qualityStatus': 'RESOLVED',
  'pendingSliceCount': 0,
  'completed': true,
  'allowedActions': <String>[],
  'items': <Map<String, dynamic>>[],
  'history': [
    {
      'stockInItemId': 'stock-in-1',
      'batchId': 'batch-1',
      'passEventId': 'pass-1',
      'goodsId': 'goods-1',
      'goodsCode': 'G-001',
      'goodsName': '测试产品',
      'colorName': '黑色',
      'unitName': '件',
      'baseQty': 5,
      'weight': 2.5,
      'weightUnitName': 'kg',
      'place': 'C-03',
      'confirmedBy': '仓库员',
      'confirmedAt': '2026-08-31T10:30:00Z',
    },
  ],
};
