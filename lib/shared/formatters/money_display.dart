/// 金额与「币种 金额」的统一显示(ADR-112 十进制原文 + ADR-128 金额带币种)。
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

/// 「币种 金额」，例如「美金 12000.00」。没有金额时只显示「—」(不单挂一个币种名)。
String financeMoneyWithCurrency(
  String? amount, {
  String? currencyName,
  String? currencyCode,
  String fallback = '原币',
}) {
  final text = amount?.trim();
  if (text == null || text.isEmpty) return '—';
  final currency = financeCurrencyText(
    name: currencyName,
    code: currencyCode,
    fallback: fallback,
  );
  return '$currency ${financeMoneyText(text)}';
}
