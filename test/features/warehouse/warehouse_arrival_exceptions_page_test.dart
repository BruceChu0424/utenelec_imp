import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_arrival_exceptions_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';

void main() {
  testWidgets(
    'desktop table single-clicks multi-select and double-click opens stock-in detail',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final api = _ArrivalExceptionApi();
      await tester.pumpWidget(_testApp(api));
      await tester.pumpAndSettle();

      var table = _table(tester);
      expect(table.selectable, isTrue);
      expect(table.idOf!(table.items.first), 'exception-1');
      expect(table.idOf!(table.items.last), 'exception-2');
      expect(find.byType(Card), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);

      await tester.tap(find.text('PR-001'));
      await tester.pump();
      table = _table(tester);
      expect(table.selectedIds, <String>{'exception-1'});
      expect(find.byType(AlertDialog), findsNothing);

      await tester.tap(find.text('PR-002'));
      await tester.pump();
      table = _table(tester);
      expect(table.selectedIds, <String>{'exception-1', 'exception-2'});
      expect(find.byType(AlertDialog), findsNothing);

      await tester.pump(const Duration(milliseconds: 400));
      await _doubleTapRow(tester, find.text('PR-002'));
      await tester.pumpAndSettle();

      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(of: dialog, matching: find.text('仓库按批准量处理')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.byKey(
            const ValueKey('warehouse-arrival-exception-stock-in-exception-2'),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('处理批准量 15 吨')),
        findsOneWidget,
      );
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      final batchAction = find.byKey(
        const Key('warehouse-arrival-exception-batch-stock-in'),
      );
      expect(batchAction, findsOneWidget);
      await tester.tap(batchAction);
      await tester.pumpAndSettle();
      expect(find.text('批量按批准量处理 2 条'), findsOneWidget);
      await tester.tap(find.text('确认批量处理'));
      await tester.pumpAndSettle();

      expect(api.batchBody?['items'], [
        {'exceptionId': 'exception-1', 'expectedVersion': 7},
        {'exceptionId': 'exception-2', 'expectedVersion': 7},
      ]);
      expect(
        api.batchBody?['idempotencyKey'],
        startsWith('arrival-stock-in-batch-'),
      );
      expect(_table(tester).items, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('375px uses the same selectable table without a task-card list', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_testApp(_ArrivalExceptionApi()));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('warehouse-arrival-exception-task-table')),
      findsOneWidget,
    );
    final table = _table(tester);
    expect(table.selectable, isTrue);
    expect(table.items.map(table.idOf!), <String>[
      'exception-1',
      'exception-2',
    ]);
    expect(find.byType(Card), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('view-only staff sees no multi-select or batch action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _testApp(_ArrivalExceptionApi(), canStockIn: false),
    );
    await tester.pumpAndSettle();

    expect(_table(tester).selectable, isFalse);
    expect(find.byType(Checkbox), findsNothing);
    expect(
      find.byKey(const Key('warehouse-arrival-exception-batch-stock-in')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _testApp(_ArrivalExceptionApi api, {bool canStockIn = true}) {
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      currentPermissionsProvider.overrideWithValue({
        Perm.warehouseInboundView,
        if (canStockIn) Perm.warehouseInboundStockIn,
      }),
      isSuperAdminProvider.overrideWithValue(false),
    ],
    child: const MaterialApp(home: WarehouseArrivalExceptionsPage()),
  );
}

MasterDataTableView<ProcurementArrivalException> _table(WidgetTester tester) {
  return tester.widget<MasterDataTableView<ProcurementArrivalException>>(
    find.byWidgetPredicate(
      (widget) => widget is MasterDataTableView<ProcurementArrivalException>,
    ),
  );
}

Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tap(finder);
}

class _ArrivalExceptionApi extends ApiClient {
  _ArrivalExceptionApi() : super(Dio());

  Map<String, dynamic>? batchBody;
  bool batchProcessed = false;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != ApiEndpoints.warehouseArrivalExceptions) {
      throw StateError('Unexpected GET $path');
    }
    return {
      'items': batchProcessed
          ? const <Map<String, dynamic>>[]
          : [
              _exception(
                id: 'exception-1',
                receiptBillNo: 'PR-001',
                status: 'RECEIPT_ADJUSTED',
                acceptedQty: 10,
                unacceptedQty: 90,
              ),
              _exception(
                id: 'exception-2',
                receiptBillNo: 'PR-002',
                status: 'RECEIPT_ADJUSTED',
                acceptedQty: 15,
                unacceptedQty: 85,
              ),
            ],
      'page': 1,
      'size': 20,
      'total': batchProcessed ? 0 : 2,
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
    expect(path, ApiEndpoints.warehouseArrivalExceptionBatchStockIn);
    batchBody = Map<String, dynamic>.from(body! as Map<String, dynamic>);
    batchProcessed = true;
    return {
      'batchId': 'arrival-batch-1',
      'replay': false,
      'submittedForInspection': true,
      'processedExceptions': 2,
      'receiptGroups': const [
        {
          'orderType': 'PURCHASE',
          'receiptId': 'receipt-exception-1',
          'receiptBillNo': 'PR-001',
          'submittedForInspection': true,
          'items': [
            {
              'exceptionId': 'exception-1',
              'expectedVersion': 7,
              'resultStatus': 'RECEIPT_POSTED',
              'resultVersion': 8,
            },
          ],
        },
        {
          'orderType': 'PURCHASE',
          'receiptId': 'receipt-exception-2',
          'receiptBillNo': 'PR-002',
          'submittedForInspection': true,
          'items': [
            {
              'exceptionId': 'exception-2',
              'expectedVersion': 7,
              'resultStatus': 'RECEIPT_POSTED',
              'resultVersion': 8,
            },
          ],
        },
      ],
    };
  }
}

Map<String, dynamic> _exception({
  required String id,
  required String receiptBillNo,
  required String status,
  required num acceptedQty,
  required num unacceptedQty,
}) => {
  'id': id,
  'orderType': 'PURCHASE',
  'receiptId': 'receipt-$id',
  'receiptItemId': 'receipt-item-$id',
  'receiptBillNo': receiptBillNo,
  'orderId': 'order-$id',
  'orderItemId': 'order-item-$id',
  'orderBillNo': 'PO-$id',
  'supplierName': '示例供应商',
  'warehouseName': '一号仓',
  'goodsCode': 'G-001',
  'goodsName': '铜材',
  'colorName': '本色',
  'unitName': '吨',
  'declaredQty': 100,
  'approvedRemainingQty': 10,
  'requestedExcessQty': 90,
  'acceptedQty': acceptedQty,
  'unacceptedQty': unacceptedQty,
  'status': status,
  'financeReason': status == 'RECEIPT_ADJUSTED' ? '批准部分入库' : null,
  'version': 7,
  'allowedActions': const <String>[],
};
