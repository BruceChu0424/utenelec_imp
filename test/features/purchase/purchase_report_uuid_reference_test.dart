import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/purchase/config/purchase_doc_config.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';

void main() {
  test('purchase request and receipt round-trip UUID report references', () {
    final request = PurchaseDocDetail.fromJson({
      'id': 'request-1',
      'departmentId': 'department-uuid',
      'items': <Object>[],
    });
    final receipt = PurchaseDocDetail.fromJson({
      'id': 'receipt-1',
      'purchaserId': 'employee-uuid',
      'items': <Object>[],
    });

    expect(request.departmentId, 'department-uuid');
    expect(receipt.purchaserId, 'employee-uuid');
    expect(PurchaseDocConfig.request.hasDepartment, isTrue);
    expect(PurchaseDocConfig.receipt.hasPurchaser, isTrue);
  });

  test('arrival prefill carries the source owner UUID as purchaser', () {
    const expectation = InboundExpectation(
      id: 'expectation-1',
      orderType: ProcurementInboundOrderType.purchase,
      orderId: 'order-1',
      billNo: 'CD-001',
      supplierId: 'supplier-1',
      warehouseId: 'warehouse-1',
      ownerEmployeeId: 'employee-7',
      status: 'OPEN',
      orderedQty: 10,
      acceptedQty: 0,
      remainingQty: 10,
      allowedActions: {'CREATE_PURCHASE_RECEIPT'},
      items: [
        InboundExpectationItem(
          id: 'expectation-item-1',
          orderItemId: 'order-item-1',
          goodsId: 'goods-1',
          goodsCode: 'V6000001',
          goodsName: '测试货品',
          unitRate: 1,
          orderedQty: 10,
          acceptedQty: 0,
          remainingQty: 10,
        ),
      ],
    );

    expect(expectation.toReceiptPrefill()?.purchaserId, 'employee-7');
  });
}
