import '../formatters/exact_decimal.dart';

const procurementLegacyQuantity = 'LEGACY_RECORDED';
const procurementChargedPlusGiftQuantity = 'CHARGED_PLUS_GIFT_V1';

String? procurementPhysicalQuantityText({
  required String? quantitySemantics,
  required String? chargedQty,
  required String? giftQty,
}) {
  if (quantitySemantics == procurementLegacyQuantity) {
    return financeExactTrimmed(chargedQty);
  }
  if (quantitySemantics != procurementChargedPlusGiftQuantity) return null;
  return financeExactTrimmed(financeExactSumTexts([chargedQty, giftQty]));
}

/// Uses the existing exact decimal units rather than a floating-point total.
String? procurementQuantityError(
  String chargedQty,
  String giftQty, {
  required bool extraGift,
}) {
  final charged = financeExactDecimalUnits(chargedQty);
  final gift = financeExactDecimalUnits(giftQty.trim().isEmpty ? '0' : giftQty);
  final maximum = BigInt.from(10).pow(18) - BigInt.one;
  if (charged == null ||
      gift == null ||
      charged.isNegative ||
      gift.isNegative ||
      charged > maximum ||
      gift > maximum) {
    return '收费数量与赠品数量必须是不小于0、整数最多14位、小数最多4位的数字';
  }
  final physical = extraGift ? charged + gift : charged;
  if (physical <= BigInt.zero || physical > maximum) {
    return '实际实物数量必须大于0，且不能超过数量上限';
  }
  return null;
}

String procurementTrancheLabel(String? tranche) => switch (tranche) {
  'CHARGED' => '收费',
  'GIFT' => '赠品',
  'LEGACY' || null => '原记录',
  _ => '数量口径未记录',
};
