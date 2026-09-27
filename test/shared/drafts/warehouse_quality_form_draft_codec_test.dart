import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_autofill_text_controller.dart';
import 'package:uten_imp/features/quality/models/production_fqc_inspection.dart';
import 'package:uten_imp/features/quality/pages/production_fqc_handling_page.dart';
import 'package:uten_imp/features/warehouse/models/arrival_form_draft_codec.dart';
import 'package:uten_imp/shared/models/inbound_allocation.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';

void main() {
  test(
    'arrival recovery retains exact source, units and intended allocation',
    () {
      const original = ProcurementReceiptPrefill(
        expectationId: 'expectation-1',
        orderType: ProcurementInboundOrderType.subcontract,
        orderBillNo: 'SC-1',
        orderId: 'order-1',
        supplierId: 'supplier-1',
        warehouseId: 'warehouse-1',
        suggestedWarehouseId: 'warehouse-2',
        purchaserId: 'buyer-1',
        items: [
          ProcurementReceiptPrefillItem(
            orderItemId: 'line-1',
            goodsId: 'goods-1',
            goodsCode: 'G1',
            goodsName: '成品',
            unitId: 'box',
            unitName: '箱',
            baseUnitId: 'piece',
            baseUnitName: '个',
            unitRate: 24,
            approvedRemainingQty: 2,
            expectedAllocations: [
              WarehouseInboundAllocation(
                kind: WarehouseInboundAllocationKind.formalDemand,
                qty: 48,
                analysisId: 'analysis-1',
                analysisMaterialId: 'material-1',
                executionSegmentId: 'segment-1',
                executionSegmentCode: 'ZX-1',
                planId: 'plan-1',
                planNo: 'SJ-1',
                targetWarehouseId: 'warehouse-2',
                actualWarehouseId: 'warehouse-1',
                warehouseMatches: false,
              ),
            ],
          ),
        ],
      );
      final restored = restoreArrivalPrefillDraft(
        arrivalPrefillDraft(original),
      );
      expect(restored.orderId, 'order-1');
      expect(restored.items.single.orderItemId, 'line-1');
      expect(restored.items.single.unitRate, 24);
      expect(
        restored.items.single.expectedAllocations.single.executionSegmentId,
        'segment-1',
      );
      expect(restored.items.single.expectedAllocations.single.qty, 48);
      expect(
        restored.items.single.expectedAllocations.single.warehouseMatches,
        isFalse,
      );
    },
  );

  test(
    'same-text user confirmation and unconfirmed autofill survive separately',
    () {
      final controller = UtenAutofillTextController(text: 'A-01');
      addTearDown(controller.dispose);
      restoreArrivalDraftText(controller, 'A-01', false);
      expect(controller.text, 'A-01');
      expect(controller.autofilled, isFalse);
      restoreArrivalDraftText(controller, 'A-01', true);
      expect(controller.autofilled, isTrue);
    },
  );

  test(
    'FQC retry restores immutable command when latest remaining is zero',
    () {
      ProductionFqcInspection inspection(double remaining) =>
          ProductionFqcInspection.fromJson({
            'id': 'inspection-1',
            'remainingQty': remaining,
            'reportedQty': 10,
            'status': remaining == 0 ? 'PASSED' : 'PENDING',
          });
      final original = FqcReportRow(inspection(10));
      addTearDown(original.dispose);
      original.pass.text = '8';
      original.fail.text = '2';
      original.disposition = 'REWORK';
      original.freezeSubmission('划痕待返工');
      final key = original.idempotencyKey;
      final restored = FqcReportRow(inspection(0));
      addTearDown(restored.dispose);
      restored.restoreFormDraft(original.toFormDraft());
      restored.pass.text = '100';
      restored.freezeSubmission('不可替换已发送原因');
      expect(restored.idempotencyKey, key);
      expect(restored.command, (
        decision: 'PARTIAL',
        passQty: 8.0,
        failQty: 2.0,
      ));
      expect(restored.submission?['reason'], '划痕待返工');
      expect(restored.validate(), isNull);
    },
  );

  test('FQC draft preserves incomplete decimal and deselection', () {
    final inspection = ProductionFqcInspection.fromJson({
      'id': 'inspection-1',
      'remainingQty': 10,
    });
    final original = FqcReportRow(inspection)
      ..pass.text = '1.'
      ..selected = false;
    final restored = FqcReportRow(inspection);
    addTearDown(original.dispose);
    addTearDown(restored.dispose);
    restored.restoreFormDraft(original.toFormDraft());
    expect(restored.pass.text, '1.');
    expect(restored.selected, isFalse);
    expect(restored.submission, isNull);
  });
}
