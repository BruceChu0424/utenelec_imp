import 'goods_bom_item.dart';

/// Copy design values only; learning quantities and audit flags belong to the original edge.
Map<String, dynamic> bomComponentCopyBody(GoodsBomItem item) => {
  'componentGoodsId': item.componentGoodsId,
  'copiedFromBomItemId': item.id,
  'qty': item.qtyExactText ?? item.qty,
  'price': item.priceExactText ?? item.price,
  'total': item.totalExactText ?? item.total,
  'summary': item.summary,
  if (!item.isPeriodicEdge) ...{
    'controlStage': item.controlStage.code,
    'consumptionBasis': item.consumptionBasis.code,
    'basisOutputQty': item.basisOutputQtyExactText ?? item.basisOutputQty,
    'allowPartialPackage': item.allowPartialPackage,
    'hardGate': item.hardGate,
  },
  if (item.colorId != null) 'colorId': item.colorId,
  if (item.defaultSupplierId != null)
    'defaultSupplierId': item.defaultSupplierId,
};
