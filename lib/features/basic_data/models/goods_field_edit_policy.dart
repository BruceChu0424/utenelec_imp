import '../../../shared/auth/permissions.dart';

/// Mirrors GoodsFieldEditPolicy; existing price, status and BOM gates stay separate.
abstract final class GoodsFieldEditPolicy {
  static const purchaseFields = {
    'sourceType',
    'minOrderQty',
    'orderMultipleQty',
    'defaultSupplierId',
    'secondarySupplierId',
    'subcontractAllowedLossPct',
  };
  static const salesFields = {
    'clientGoodsName',
    'cNumber',
    'clientId',
    'nameEn',
  };
  static bool canEditAny(Set<String> permissions) => permissions.any(
    {
      Perm.goodsEdit,
      Perm.goodsPurchaseEdit,
      Perm.goodsSalesEdit,
      Perm.goodsPriceEdit,
      Perm.goodsNameEnEdit,
    }.contains,
  );
  static bool canEditField(String key, Set<String> permissions) {
    if (key == 'nameEn' && permissions.contains(Perm.goodsNameEnEdit)) {
      return true;
    }
    if (purchaseFields.contains(key)) {
      return permissions.contains(Perm.goodsPurchaseEdit);
    }
    if (salesFields.contains(key)) {
      return permissions.contains(Perm.goodsSalesEdit);
    }
    if (key == 'price' || key == 'discount') {
      return permissions.contains(Perm.goodsPriceEdit);
    }
    if (key == 'status') return permissions.contains(Perm.goodsStatus);
    return permissions.contains(Perm.goodsEdit);
  }
}
