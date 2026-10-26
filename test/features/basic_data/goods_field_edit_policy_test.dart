import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_field_edit_policy.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test(
    'goods edit groups remain independent, including existing narrow English-name authority',
    () {
      expect(
        GoodsFieldEditPolicy.canEditField('name', {Perm.goodsEdit}),
        isTrue,
      );
      for (final key in GoodsFieldEditPolicy.purchaseFields) {
        expect(
          GoodsFieldEditPolicy.canEditField(key, {Perm.goodsEdit}),
          isFalse,
        );
        expect(
          GoodsFieldEditPolicy.canEditField(key, {Perm.goodsPurchaseEdit}),
          isTrue,
        );
        expect(
          GoodsFieldEditPolicy.canEditField(key, {Perm.goodsSalesEdit}),
          isFalse,
        );
      }
      for (final key in GoodsFieldEditPolicy.salesFields) {
        expect(
          GoodsFieldEditPolicy.canEditField(key, {Perm.goodsEdit}),
          isFalse,
        );
        expect(
          GoodsFieldEditPolicy.canEditField(key, {Perm.goodsSalesEdit}),
          isTrue,
        );
      }
      expect(
        GoodsFieldEditPolicy.canEditField('nameEn', {Perm.goodsNameEnEdit}),
        isTrue,
      );
      expect(
        GoodsFieldEditPolicy.canEditField('price', {Perm.goodsSalesEdit}),
        isFalse,
      );
      expect(GoodsFieldEditPolicy.canEditAny({Perm.goodsPurchaseEdit}), isTrue);
      expect(GoodsFieldEditPolicy.canEditAny({Perm.goodsView}), isFalse);
    },
  );
}
