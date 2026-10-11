/// 金额与「金额 币种」的统一显示(ADR-112 十进制原文 + ADR-128 金额带币种)。
///
/// 全平台只有这一处决定「金额怎么写、币种名怎么取」：币种名复用
/// [financeCurrencyDisplayLabel](只用主档名称或可读代码，从不显示 001 这类旧编号)，
/// 金额复用 [financeExactMoneyDisplay](至少 2 位小数、去掉多余的 0，不经过 double、不四舍五入)。
/// 页面不要再各写私有的 `_money` / `_currencyLabel`。
library;

import '../../core/utils/currency_display.dart';
import 'exact_decimal.dart';

/// 金额原文显示：空值显示「—」；不是数字的原文原样返回(不猜)。
String financeMoneyText(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) return '—';
  return financeExactDecimal(text) == null
      ? text
      : financeExactMoneyDisplay(text);
}

/// 币种显示名：主档名称优先，缺名称时退回可读代码，都没有时用 [fallback]。
String financeCurrencyText({
  String? name,
  String? code,
  String fallback = '原币',
}) => financeCurrencyDisplayLabel(name: name, code: code) ?? fallback;

/// 本位币的后缀短名：金额带币种时「人民币」显示为「元」(2026-10-10 用户口径
/// 「单价 0.5 元、总金额 1500 美金」)，其余币种沿用主档名称(美金/港币)。
String? _currencyUnitSuffix(String? currencyName, String? currencyCode) {
  final label = financeCurrencyDisplayLabel(
    name: currencyName,
    code: currencyCode,
  );
  if (label == null) return null;
  return label == '人民币' ? '元' : label;
}

/// 「金额 币种」后缀式(ADR-128 → 2026-10-10 用户口径：金额后自动带单位)，
/// 例如「12000.00 美金」「0.50 元」。与 [formatQtyWithUnit] 的「数量 单位」
/// 对称，是金额侧唯一拼装点。缺币种信息或金额不是数字（「—」「***」等哨兵
/// 原文）时只显金额原文，不猜币种、不拼单位。
String financeMoneyWithUnitSuffix(
  String? amount, {
  String? currencyName,
  String? currencyCode,
}) {
  final text = amount?.trim();
  if (text == null || text.isEmpty) return '—';
  if (financeExactDecimal(text) == null) return text;
  final unit = _currencyUnitSuffix(currencyName, currencyCode);
  return unit == null
      ? financeMoneyText(text)
      : '${financeMoneyText(text)} $unit';
}

/// 本位币金额的「金额 元」后缀(折合人民币列/合计等已知恒为本币的场合)。
String financeLocalMoneyWithUnitSuffix(String? amount) =>
    financeMoneyWithUnitSuffix(amount, currencyName: '人民币');
