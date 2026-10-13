import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/purchase/config/purchase_doc_config.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_edit_page.dart';

void main() {
  test('typed decomposition keeps exact charged and gift facts separate', () {
    final line = ProcurementDecompositionLine.fromJson({
      'sourceDocumentId': 'r',
      'sourceItemId': 'i',
      'goodsId': 'g',
      'quantitySemantics': 'CHARGED_PLUS_GIFT_V1',
      'requestedQtyExact': '12345678901234.0001',
      'orderedQtyExact': '12345678901234.0000',
      'pendingQtyExact': '0',
      'remainingQty': 0.1,
      'remainingQtyExact': '0.0001',
      'giftQtyExact': '0.0009',
      'giftOrderedQtyExact': '0.0002',
      'pendingGiftQtyExact': '0.0003',
      'remainingGiftQtyExact': '0.0004',
      'physicalRemainingQtyExact': '0.0005',
      'unitRateExact': '1.123456',
    });
    expect(line.requestedQtyText, '12345678901234.0001');
    expect(line.orderedQtyText, '12345678901234.0000');
    expect(line.pendingQtyText, '0');
    expect(line.remainingQty, 0.0001);
    expect(line.chargedRemainingQtyText, '0.0001');
    expect(line.giftQtyText, '0.0009');
    expect(line.giftOrderedQtyText, '0.0002');
    expect(line.pendingGiftQtyText, '0.0003');
    expect(line.defaultGiftQtyText, '0.0004');
    expect(line.availablePhysicalQtyText, '0.0005');
    expect(line.unitRateText, '1.123456');
  });

  test(
    'legacy decomposition and constructor retain their original quantity',
    () {
      const old = ProcurementDecompositionLine(
        sourceDocumentId: 'r',
        sourceDocumentNo: 'CS',
        sourceItemId: 'i',
        goodsId: 'g',
        requestedQty: 10,
        orderedQty: 2,
        pendingQty: 3,
        remainingQty: 5,
      );
      expect(old.quantitySemantics, 'LEGACY_RECORDED');
      expect(old.defaultGiftQtyText, '0');
      expect(old.availablePhysicalQtyText, '5.0');
      final annotated = ProcurementDecompositionLine.fromJson({
        'sourceDocumentId': 'r',
        'sourceItemId': 'i',
        'goodsId': 'g',
        'requestedQty': 10,
        'remainingQtyExact': '5',
        'giftQty': 2,
        'remainingGiftQtyExact': '2',
      });
      expect(annotated.defaultGiftQtyText, '0');
      expect(annotated.availablePhysicalQtyText, '5');
    },
  );

  // 订货单支持从管理卡片直达新建（与销售/财务一致，见 purchase_doc_config.dart 注释），
  // 但明细仍必须经「从上游引入」来自计划申请（linkToRequestItem）；申请单本身只读。
  test(
    'planning request is read-only; orders may be created directly but source lines from planning',
    () {
      expect(PurchaseDocConfig.request.allowDirectCreate, isFalse);
      expect(PurchaseDocConfig.request.skipListOnCreate, isFalse);
      expect(PurchaseDocConfig.request.hasSupplier, isFalse);
      expect(PurchaseDocConfig.request.hasCurrency, isFalse);

      expect(PurchaseDocConfig.order.allowDirectCreate, isTrue);
      expect(PurchaseDocConfig.order.skipListOnCreate, isTrue);
      expect(PurchaseDocConfig.order.supplierRequired, isTrue);
      expect(PurchaseDocConfig.order.hasSettlement, isTrue);
      expect(PurchaseDocConfig.order.settlementRequired, isTrue);
      expect(PurchaseDocConfig.order.linkToRequestItem, isTrue);

      expect(PurchaseDocConfig.receipt.hasSettlement, isTrue);
      expect(PurchaseDocConfig.receipt.settlementRequired, isFalse);
      expect(PurchaseDocConfig.returnDoc.hasSettlement, isTrue);
      expect(PurchaseDocConfig.returnDoc.settlementRequired, isFalse);
    },
  );

  test(
    'decomposition preview keeps every source line and pending allocation',
    () {
      final line = ProcurementDecompositionLine.fromJson({
        'sourceDocumentId': 'request-2',
        'sourceDocumentNo': 'CS-002',
        'sourceItemId': 'item-9',
        'goodsId': 'goods-3',
        'requestedQty': 10,
        'orderedQty': 2,
        'pendingQty': 3,
        'remainingQty': 5,
        'warehouseId': 'warehouse-1',
        'sourcePlanNo': 'PP-001',
      });

      expect(line.sourceItemId, 'item-9');
      expect(line.pendingQty, 3);
      expect(line.remainingQty, 5);
    },
  );

  test('save action labels state the next workflow step', () {
    expect(
      purchaseSaveActionLabel(PurchaseDocType.order, submitFinance: true),
      '保存并提交财务审核',
    );
    expect(
      purchaseSaveActionLabel(PurchaseDocType.order, submitFinance: false),
      '保存订货单草稿',
    );
    expect(
      purchaseSaveActionLabel(PurchaseDocType.receipt, submitFinance: false),
      '保存，下一步审核',
    );
    expect(
      purchaseSaveActionLabel(PurchaseDocType.returnDoc, submitFinance: false),
      '保存，下一步审核',
    );
  });
}
