import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/models/procurement_iqc_rejection.dart';

void main() {
  test('stable list and detail routes preserve source hub', () {
    expect(
      RoutePath.procurementIqcRejections(source: 'warehouse'),
      '/procurement/iqc-rejections?from=warehouse',
    );
    expect(
      RoutePath.procurementIqcRejectionDetail('case-1', source: 'finance'),
      '/procurement/iqc-rejections/case-1?from=finance',
    );
  });

  test('case parsing keeps server mask authoritative', () {
    final masked = ProcurementIqcRejectionCase.fromJson({
      ..._caseJson,
      'priceMasked': true,
      'failedAmountLocal': '125.5000',
    });
    final visible = ProcurementIqcRejectionCase.fromJson({
      ..._caseJson,
      'priceMasked': false,
      'failedAmountLocal': '125.5000',
    });

    expect(masked.receiptType, ProcurementIqcReceiptType.subcontract);
    expect(masked.status, ProcurementIqcRejectionStatus.returnRecorded);
    expect(masked.allows(ProcurementIqcRejectionAction.confirmCredit), isTrue);
    expect(masked.amountLabel(masked.failedAmountLocal), '***');
    expect(visible.amountLabel(visible.failedAmountLocal), 'CNY 125.5000');
  });

  test(
    'detail parses events and replacement allocations without flattening',
    () {
      final detail = ProcurementIqcRejectionDetail.fromJson({
        'caseItem': _caseJson,
        'events': [
          {
            'id': 'event-1',
            'eventType': 'RETURN_RECORDED',
            'commandId': 'command-1',
            'reference': 'RET-001',
            'eventDate': '2026-08-31',
            'reason': '供应商签收',
            'createdAt': '2026-08-31T10:00:00Z',
          },
        ],
        'replacementAllocations': [
          {
            'id': 'allocation-1',
            'replacementReceiptType': 'PURCHASE',
            'replacementReceiptId': 'receipt-2',
            'replacementReceiptItemId': 'receipt-item-2',
            'allocatedBaseQty': '3',
            'allocatedQty': '1.5',
            'allocatedAmountOriginal': '10.0000',
            'allocatedAmountLocal': '10.0000',
            'status': 'ACTIVE',
          },
        ],
      });

      expect(detail.events.single.reference, 'RET-001');
      expect(detail.replacementAllocations.single.allocatedBaseQty, '3');
      expect(detail.replacementAllocations.single.allocatedQty, '1.5');
    },
  );

  test('counts separate open and terminal workload', () {
    final counts = ProcurementIqcRejectionCounts.fromJson({
      'total': 15,
      'pendingReturn': 3,
      'returnRecorded': 2,
      'creditConfirmed': 4,
      'closedNoCredit': 1,
      'financeException': 2,
      'reversed': 3,
    });

    expect(counts.open, 7);
    expect(counts.terminal, 8);
  });

  test(
    'commands always carry expectedVersion commandId and structured dates',
    () {
      expect(
        const ProcurementIqcRecordReturnCommand(
          expectedVersion: 7,
          commandId: 'command-1',
          returnReference: ' RET-001 ',
          returnDate: '2026-08-31',
          returnNote: ' 已退回 ',
        ).toJson(),
        {
          'expectedVersion': 7,
          'commandId': 'command-1',
          'returnReference': 'RET-001',
          'returnDate': '2026-08-31',
          'returnNote': '已退回',
        },
      );
    },
  );
}

const _caseJson = <String, dynamic>{
  'id': 'case-1',
  'receiptType': 'SUBCONTRACT',
  'receiptId': 'receipt-1',
  'receiptItemId': 'receipt-item-1',
  'inspectionItemId': 'inspection-item-1',
  'receiptBillNo': 'EW-001',
  'orderBillNo': 'WW-001',
  'supplierId': 'supplier-1',
  'supplierName': '测试委外商',
  'goodsCode': 'G-001',
  'goodsName': '电镀件',
  'failedBaseQty': '5',
  'failedQty': '5',
  'unitName': '件',
  'failedAmountOriginal': '125.5000',
  'failedAmountLocal': '125.5000',
  'currencyCode': 'CNY',
  'status': 'RETURN_RECORDED',
  'version': 7,
  'ownerUserId': 'user-1',
  'returnReference': 'RET-001',
  'returnDate': '2026-08-31',
  'returnNote': '供应商已签收',
  'allowedActions': ['CONFIRM_CREDIT', 'CLOSE_NO_CREDIT', 'REVERSE'],
  'priceMasked': true,
};
