import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_revision_table.dart';
import 'package:uten_imp/features/warehouse/widgets/arrival_qty_revision_table.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';

ProcurementArrivalException task({
  String status = 'PENDING_FINANCE',
  num accepted = 0,
  bool masked = false,
}) => ProcurementArrivalException.fromJson({
  'id': 'exception',
  'orderType': 'PURCHASE',
  'receiptId': 'receipt',
  'receiptItemId': 'receipt-item',
  'receiptBillNo': 'PR-001',
  'orderId': 'order',
  'orderItemId': 'order-item',
  'orderBillNo': 'PO-001',
  'goodsCode': 'G-001',
  'goodsName': '铜材',
  'colorName': '本色',
  'unitName': '吨',
  'declaredQty': 100,
  'acceptedQty': accepted,
  'status': status,
  'unitPrice': '9007199254740993.1234',
  'priceMasked': masked,
  'version': 1,
});

void main() {
  test('pending default zero never masquerades as a removed row', () {
    final rows = arrivalQtyRevisionRows(task());
    expect(rows.single.kind, UtenRevisionKind.unchanged);
    expect(rows.single.value.qty, 100);
    expect(rows.single.label, '原申报');
  });

  test('accepted partial quantity keeps full old and new identity', () {
    final source = task(status: 'RECEIPT_ADJUSTED', accepted: 15.123456);
    final rows = arrivalQtyRevisionRows(source);
    expect(rows.map((row) => row.kind), [
      UtenRevisionKind.removed,
      UtenRevisionKind.added,
    ]);
    expect(rows.map((row) => row.value.qty), [100, 15.123456]);
    expect(rows.every((row) => identical(row.value.task, source)), isTrue);
    expect(rows.last.label, '批准接收');
    expect(rows.first.changedKeys, isEmpty);
    expect(rows.last.changedKeys, {'qty'});
  });

  test(
    'accepted zero deletes the receipt row without an invented zero row',
    () {
      final rows = arrivalQtyRevisionRows(task(status: 'RETURN_REQUIRED'));
      expect(rows.single.kind, UtenRevisionKind.removed);
      expect(rows.single.label, '已删除');
    },
  );

  test('accepting all leaves the unchanged row neutral', () {
    final rows = arrivalQtyRevisionRows(
      task(status: 'RECEIPT_ADJUSTED', accepted: 100),
    );
    expect(rows.single.kind, UtenRevisionKind.unchanged);
    expect(rows.single.label, '数量未变');
  });

  test(
    'explicit preview is marked proposed and does not mutate saved facts',
    () {
      final source = task();
      final rows = arrivalQtyRevisionRows(source, proposedQty: 15);
      expect(rows.last.label, '拟接收');
      expect(rows.last.changedKeys, {'qty'});
      expect(rows.last.value.qty, 15);
      expect(source.acceptedQty, 0);
      expect(arrivalQtyHasDecision(source), isFalse);
      final deletion = arrivalQtyRevisionRows(source, proposedQty: 0);
      expect(deletion.single.label, '拟删除');
    },
  );

  for (final width in [375.0, 1200.0]) {
    testWidgets(
      'masked revision at $width px hides prices and keeps full rows',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ArrivalQtyRevisionTable(
                  task: task(
                    status: 'RECEIPT_ADJUSTED',
                    accepted: 15,
                    masked: true,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final table = tester.widget<UtenRevisionTable<ArrivalQtyRevisionLine>>(
          find.byKey(const Key('arrival-qty-revision-table')),
        );
        expect(table.rows, hasLength(2));
        expect(table.columns.map((column) => column.key), [
          'goodsName',
          'goodsCode',
          'color',
          'unit',
          'qty',
        ]);
        expect(find.byType(UtenRevisionStrike), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
