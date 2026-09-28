// 报价核价的「成交单价 ↔ 折扣」换算预览(ADR-134)。
//
// 与服务端 MoneyPolicy.discountFromUnitPrice(成交单价, 汇率 1, 标价) 同一口径:
//   折扣 = 成交单价 ÷ 标价, 先按 12 位小数四舍五入, 再按折扣列 4 位四舍五入;
//   标价为空或不大于 0 → 不能用折扣表示(要财务直接定价);
//   成交单价为空或不大于 0 → 无效;
//   取位后大于 1(高于标价) → 不能用折扣表示, 绝不截成 1。
// 全程十进制整数运算, 不经过 double(ADR-112)。这里只做页面预览, 保存时服务端按同一
// 规则再算一遍并以服务端为准。
import '../../../shared/formatters/exact_decimal.dart';

/// 换算结论(与服务端 DiscountFlag 一一对应)。
enum QuoteDiscountFlag {
  /// 折扣正好表示成交单价。
  ok,

  /// 折扣取 4 位后与成交单价有尾差(见 [QuoteDiscountResult.unitGap])。
  rounded,

  /// 成交单价高于标价, 折扣会大于 1。
  aboveList,

  /// 货品没有标价(空或 0), 只能由财务直接定成交单价。
  noListPrice,

  /// 成交单价不是大于 0 的数字。
  invalid,
}

class QuoteDiscountResult {
  const QuoteDiscountResult(this.flag, {this.discount, this.unitGap});

  final QuoteDiscountFlag flag;

  /// 4 位小数折扣文本(如 0.9500); 只有 ok / rounded 时有值。
  final String? discount;

  /// |成交单价 − 标价 × 折扣| 的单件尾差; 只有 ok / rounded 时有值。
  final String? unitGap;

  bool get hasDiscount => discount != null;
}

/// 折扣列小数位(与 financeExactDecimalUnits 默认 4 位一致)。
const int _discountScale = 4;
const int _divisionScale = _discountScale + 8;

/// 十进制文本 → (带符号整数, 小数位数)；不是数字返回 null。
(BigInt, int)? _parse(String? raw) {
  final text = financeExactDecimal(raw?.trim());
  if (text == null) return null;
  final scale = text.contains('.') ? text.length - text.indexOf('.') - 1 : 0;
  final units = financeExactDecimalUnits(text, scale: scale);
  return units == null ? null : (units, scale);
}

/// HALF_UP 整除(被除数、除数均为正)。
BigInt _divHalfUp(BigInt numerator, BigInt denominator) {
  final quotient = numerator ~/ denominator;
  final remainder = numerator % denominator;
  return remainder * BigInt.two >= denominator
      ? quotient + BigInt.one
      : quotient;
}

/// 由成交单价反推折扣(汇率 1)。
QuoteDiscountResult quoteDiscountFromDealPrice(
  String? dealPrice,
  String? listPrice,
) {
  final list = _parse(listPrice);
  if (list == null || list.$1 <= BigInt.zero) {
    return const QuoteDiscountResult(QuoteDiscountFlag.noListPrice);
  }
  final deal = _parse(dealPrice);
  if (deal == null || deal.$1 <= BigInt.zero) {
    return const QuoteDiscountResult(QuoteDiscountFlag.invalid);
  }
  // 对齐到同一小数位后整数相除: q12 = round(deal / list, 12)，再 round(q12, 4)。
  final commonScale = deal.$2 > list.$2 ? deal.$2 : list.$2;
  final dealUnits = deal.$1 * BigInt.from(10).pow(commonScale - deal.$2);
  final listUnits = list.$1 * BigInt.from(10).pow(commonScale - list.$2);
  final q12 = _divHalfUp(
    dealUnits * BigInt.from(10).pow(_divisionScale),
    listUnits,
  );
  final q4 = _divHalfUp(
    q12,
    BigInt.from(10).pow(_divisionScale - _discountScale),
  );
  if (q4 <= BigInt.zero) {
    return const QuoteDiscountResult(QuoteDiscountFlag.invalid);
  }
  if (q4 > BigInt.from(10).pow(_discountScale)) {
    return const QuoteDiscountResult(QuoteDiscountFlag.aboveList);
  }
  final discount = financeExactDecimalFromUnits(q4);
  // 尾差 = |成交单价 − 标价 × 折扣|，精确到 commonScale + 4 位。
  final gapScale = commonScale + _discountScale;
  final gapUnits =
      (dealUnits * BigInt.from(10).pow(_discountScale) - listUnits * q4).abs();
  final gap = financeExactTrimmed(
    financeExactDecimalFromUnits(gapUnits, scale: gapScale),
  );
  return QuoteDiscountResult(
    gapUnits == BigInt.zero ? QuoteDiscountFlag.ok : QuoteDiscountFlag.rounded,
    discount: discount,
    unitGap: gap,
  );
}

/// 折扣是否合法: 0 < 折扣 ≤ 1，最多 4 位小数。
bool isValidQuoteDiscount(String? raw) {
  final text = raw?.trim() ?? '';
  final units = financeExactDecimalUnits(text);
  if (units == null) return false;
  return units > BigInt.zero && units <= BigInt.from(10).pow(_discountScale);
}

/// 折扣统一写成 4 位小数文本(0.95 → 0.9500)；不合法返回 null。
String? normalizeQuoteDiscount(String? raw) {
  if (!isValidQuoteDiscount(raw)) return null;
  final units = financeExactDecimalUnits(raw!.trim())!;
  return financeExactDecimalFromUnits(units);
}

/// 成交单价是否是合法的财务定价(≥ 0 的数字；0 = 赠品/0价)。
bool isValidFinancePrice(String? raw) {
  final parsed = _parse(raw);
  return parsed != null && !(raw?.trim().startsWith('-') ?? false);
}

/// 由折扣推成交单价: 标价 × 折扣(精确乘积，去掉末尾 0)；任一为空返回 null。
String? quoteDealPriceFromDiscount(String? listPrice, String? discount) {
  final list = financeExactDecimal(listPrice?.trim());
  final rate = financeExactDecimal(discount?.trim());
  if (list == null || rate == null) return null;
  return financeExactTrimmed(financeExactMultiplyTexts([list, rate]));
}

/// 行金额预览: 数量 × 单价 × 折扣(精确)；任一缺失返回 null。
String? quoteLineAmountPreview({
  required String? qty,
  required String? price,
  required String? discount,
}) {
  final q = financeExactDecimal(qty?.trim());
  final p = financeExactDecimal(price?.trim());
  final d = financeExactDecimal(discount?.trim());
  if (q == null || p == null || d == null) return null;
  return financeExactTrimmed(financeExactMultiplyTexts([q, p, d]));
}

/// 与客户文件的差额 = 行金额 − 文件单价(已折合本币) × 数量；任一缺失返回 null。
String? quoteFileDifference({
  required String? lineAmount,
  required String? qty,
  required String? filePriceLocal,
}) {
  final amount = financeExactDecimal(lineAmount?.trim());
  final q = financeExactDecimal(qty?.trim());
  final file = financeExactDecimal(filePriceLocal?.trim());
  if (amount == null || q == null || file == null) return null;
  final fileAmount = financeExactMultiplyTexts([q, file]);
  if (fileAmount == null) return null;
  final negated = fileAmount.startsWith('-')
      ? fileAmount.substring(1)
      : '-$fileAmount';
  return financeExactTrimmed(financeExactSumTexts([amount, negated]));
}

/// 十进制文本的正负号(-1 / 0 / 1)；空或不是数字返回 null。精确比较，不经过 double。
int? quoteDecimalSign(String? raw) => _parse(raw)?.$1.sign;

/// 十进制文本是否大于 0(空、非数字返回 false)。
bool isPositiveDecimal(String? raw) => quoteDecimalSign(raw) == 1;

/// 十进制文本是否为 0(空、非数字返回 false)。
bool isZeroDecimal(String? raw) {
  final text = financeExactDecimal(raw?.trim());
  return text != null && RegExp(r'^-?0+(\.0+)?$').hasMatch(text);
}

/// 十进制文本比较：a 与 b 数值相等(不看末尾 0)；任一不是数字返回 false。
bool sameDecimal(String? a, String? b) {
  final left = financeExactTrimmed(financeExactDecimal(a?.trim()));
  final right = financeExactTrimmed(financeExactDecimal(b?.trim()));
  return left != null && left == right;
}
