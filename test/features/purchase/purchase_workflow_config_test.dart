import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/purchase/config/purchase_doc_config.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_edit_page.dart';

void main() {
  // 订货单支持从管理卡片直达新建（与销售/财务一致，见 purchase_doc_config.dart 注释），
  // 但明细仍必须经「从上游引入」来自计划申请（linkToRequestItem）；申请单本身只读。
  test('planning request is read-only; orders may be created directly but source lines from planning', () {
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
  });

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
