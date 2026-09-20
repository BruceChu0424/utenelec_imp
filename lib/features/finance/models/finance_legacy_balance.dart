import 'finance_decimal.dart';

/// 历史余额可由新收付款结算，但负数不能推断为预收、预付或贷项。
String? financeLegacyBalanceBlockReason({
  required String? originalBalance,
  required String? currencyId,
}) {
  final balance = financeAmountUnits(originalBalance);
  if (balance == null) return '历史原币余额待财务核验，暂不能引用';
  if (currencyId == null || currencyId.trim().isEmpty) {
    return '币别待财务核验，暂不能引用';
  }
  if (balance <= BigInt.zero) {
    return '历史余额必须为正数；零余额或负余额不能直接作为收付款或抵扣来源';
  }
  return null;
}

String financeLegacySourceResolutionLabel(String? status) => switch (status) {
  'EXACT_SOURCE' => '原单唯一匹配',
  'AMBIGUOUS_SOURCE' => '原单有多个匹配',
  'MISSING_OR_CONFLICTING_SOURCE' => '原单缺失或关系不一致',
  'UNVERIFIED_SOURCE_KIND' => '旧来源类型待核验',
  _ => '—',
};
