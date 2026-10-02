import '../../../shared/business_columns/business_column.dart';
// 报价核价页的一行编辑状态(ADR-134)：成交单价与折扣两个输入框联动。
//
// 定价来源由成交单价自动决定, 与服务端 applyDealPrice 同一规则(SPEC §6.2):
//   · 有标价且成交单价不高于标价 → 按标价打折(MASTER): 改「成交单价」自动反推 4 位折扣,
//     改「折扣」自动算成交单价; 价格仍是货品资料标价(销售改不了价);
//   · 没有标价(空/0), 或成交单价高于标价 → 财务直接定价(FINANCE, 折扣固定 1);
//     高于标价时就地提示「按财务定价」, 不是死路报错;
//   · 0 = 赠品/0价: 有标价的行只能从行菜单显式设置; 没有标价的行填 0 即是赠品。
// 低于标价的成交单价永远折成折扣(不会变成财务定价), 折扣列、报表和转单锁定的折扣都看得见。
// 联动由输入框 onChanged 驱动；程序回填另一个框不触发 onChanged，所以不会来回打架。
import 'package:flutter/widgets.dart';

import 'quote_finance_pricing.dart';
import 'sales_quote_finance_review.dart';

/// 行校验错误(界面映射成 arb 文案)。
enum QuoteFinanceLineError {
  /// 成交单价不是大于 0 的数字(按标价打折时; 0 价请用「设为赠品/0价」)。
  dealPrice,

  /// 财务定价不是不小于 0 的数字。
  financePrice,

  /// 折扣不在 (0, 1] 或超过 4 位小数。
  discount,

  /// 财务定价行还没填成交单价。
  needPrice,

  /// Existing extra terms produce an invalid amount after repricing.
  extraAmount,
  quantity,
}

class QuoteFinanceLineDraft {
  QuoteFinanceLineDraft(this.line)
    : _initialSource = line.priceSource,
      source = line.priceSource {
    _initialDeal = financeTrim(
      line.dealPrice ??
          (line.storedPrice == null
              ? null
              : quoteDealPriceFromDiscount(
                  line.storedPrice,
                  normalizeQuoteDiscount(line.discount) ?? '1',
                )),
    );
    _initialDiscount = normalizeQuoteDiscount(line.discount) ?? '1.0000';
    directPricing = line.isFinancePriced && !sameDecimal(_initialDiscount, '1');
    qty.text = line.qty ?? '';
    price.text = line.storedPrice ?? '';
    deal.text = _initialDeal;
    discount.text = financeTrim(_initialDiscount);
  }

  final SalesQuoteFinanceLine line;
  final TextEditingController qty = TextEditingController();
  final TextEditingController price = TextEditingController();
  bool directPricing = false;
  bool removed = false;
  final TextEditingController deal = TextEditingController();
  final TextEditingController discount = TextEditingController();

  /// 将提交的定价来源。
  String source;
  QuoteFinanceLineError? _error;
  QuoteFinanceLineError? get error {
    if (removed) return null;
    if (!isPositiveDecimal(qty.text)) return QuoteFinanceLineError.quantity;
    if (directPricing && !isValidFinancePrice(price.text)) {
      return QuoteFinanceLineError.financePrice;
    }
    if (directPricing && !isValidQuoteDiscount(discount.text)) {
      return QuoteFinanceLineError.discount;
    }
    if (_error != null) return _error;
    if (line.extraColumns.isEmpty) return null;
    final base = quoteLineAmountPreview(
      qty: qty.text,
      price: effectivePrice,
      discount: effectiveDiscount,
    );
    return base != null && businessColumnAmount(base, line.extraColumns) == null
        ? QuoteFinanceLineError.extraAmount
        : null;
  }

  set error(QuoteFinanceLineError? value) => _error = value;

  /// 已选「按最新标价刷新」(保存前本行单价/折扣不可再改)。
  bool refreshing = false;

  final String _initialSource;
  late final String _initialDeal;
  late final String _initialDiscount;

  String get itemId => line.itemId;

  /// 反推折扣用的标价: 刷新时 = 货品资料最新标价, 否则与服务端取同一个([SalesQuoteFinanceLine.listPrice])。
  String? get listPrice =>
      refreshing ? line.currentMasterPrice : line.listPrice;

  bool get hasListPrice => isPositiveDecimal(listPrice);

  /// 没有标价：只能财务直接定价。
  bool get forcedFinance => !hasListPrice;

  bool get isMaster =>
      (source == QuotePriceSource.master || source == QuotePriceSource.sales) &&
      hasListPrice;

  /// 成交单价 / 折扣输入框可编辑(刷新标价后要先保存)。
  bool get priceEditable => !refreshing && !removed;

  /// 折扣框可编辑(按标价打折且有标价)。
  bool get discountEditable =>
      (directPricing || isMaster || line.storedPrice != null) && priceEditable;

  /// 财务定价且成交单价为 0 = 赠品/0价。
  bool get isGiveaway =>
      source == QuotePriceSource.finance && isZeroDecimal(deal.text);

  /// 成交单价高于标价, 已按财务定价(提示用, 不是错误)。
  bool get aboveList =>
      !isMaster &&
      hasListPrice &&
      quoteDiscountFromDealPrice(deal.text, listPrice).flag ==
          QuoteDiscountFlag.aboveList;

  /// 生效单价：按标价打折 = 标价；财务定价 = 成交单价。
  String? get effectivePrice => directPricing
      ? _nonEmpty(price.text)
      : isMaster
      ? listPrice
      : _nonEmpty(deal.text);

  /// 生效折扣：按标价打折 = 折扣框；财务定价 = 1。
  String? get effectiveDiscount => directPricing || isMaster
      ? (isValidQuoteDiscount(discount.text) ? discount.text.trim() : null)
      : '1';

  /// 还没有价格(以本行当前状态为准: 改过看页面, 没改看服务端)。
  bool get unpriced => dirty ? effectivePrice == null : line.needsFinancePrice;

  /// 金额预览(数量 × 单价 × 折扣，精确)；没改的行直接用服务端金额。
  String? get amountPreview => removed
      ? '0'
      : dirty
      ? businessColumnAmount(
          quoteLineAmountPreview(
            qty: qty.text,
            price: effectivePrice,
            discount: effectiveDiscount,
          ),
          line.extraColumns,
        )
      : line.amount;

  /// 与客户文件的差额预览；没改的行直接用服务端差额。
  String? get fileDifference => dirty
      ? quoteFileDifference(
          lineAmount: amountPreview,
          qty: qty.text,
          filePriceLocal: line.clientPriceLocal,
        )
      : (line.diffToFile ??
            quoteFileDifference(
              lineAmount: line.amount,
              qty: qty.text,
              filePriceLocal: line.clientPriceLocal,
            ));

  /// 与上次财务确认的折扣不同(销售改后重新提交时标黄)。
  bool get differsFromLastConfirmed {
    final last = line.lastFinanceConfirmedDiscount;
    if (last == null) return false;
    return !sameDecimal(last, effectiveDiscount ?? discount.text);
  }

  /// 本行有要处理的内容: 填错了(不能悄悄丢掉)、选了刷新标价、或值与服务端不同。
  bool get dirty {
    if (removed || !sameDecimal(qty.text, line.qty)) return true;
    if (directPricing) {
      return !sameDecimal(price.text, line.storedPrice) ||
          !sameDecimal(discount.text, _initialDiscount);
    }
    if (error != null) return true;
    if (refreshing) return true;
    if (source != _initialSource) return true;
    if (isMaster) {
      // 冻结标价在用的行只看折扣; 还没有单价的行填了成交单价就算改动。
      if (line.pricedFromFrozenList) {
        return !sameDecimal(
          normalizeQuoteDiscount(discount.text) ?? discount.text,
          _initialDiscount,
        );
      }
      return !_sameDeal(deal.text, _initialDeal);
    }
    return !_sameDeal(deal.text, _initialDeal);
  }

  bool get valid {
    if (removed) return true;
    if (error != null) return false;
    if (refreshing) return true;
    if (directPricing) {
      return isValidFinancePrice(price.text) &&
          isValidQuoteDiscount(discount.text);
    }
    if (isMaster) return isValidQuoteDiscount(discount.text);
    return isValidFinancePrice(deal.text);
  }

  /// 用户改了成交单价：按标价自动决定打折还是财务定价。
  void onDealChanged(String text) {
    if (!priceEditable) return;
    directPricing = false;
    final trimmed = text.trim();
    // 本来就没有单价的行又清空了：回到原样(不算填错，也不挡保存别的行)。
    if (trimmed.isEmpty && _initialDeal.isEmpty) {
      restore();
      return;
    }
    if (forcedFinance) {
      source = QuotePriceSource.finance;
      discount.text = '1';
      error = trimmed.isEmpty
          ? QuoteFinanceLineError.needPrice
          : isValidFinancePrice(trimmed)
          ? null
          : QuoteFinanceLineError.financePrice;
      return;
    }
    final result = quoteDiscountFromDealPrice(trimmed, listPrice);
    switch (result.flag) {
      case QuoteDiscountFlag.ok:
      case QuoteDiscountFlag.rounded:
        source = QuotePriceSource.master;
        discount.text = financeTrim(result.discount);
        error = null;
      case QuoteDiscountFlag.aboveList:
        // SPEC §6.2: 高于标价 → 财务定价(单价 = 成交单价, 折扣 1), 与服务端 dealPrice 一致。
        source = QuotePriceSource.finance;
        discount.text = '1';
        error = null;
      case QuoteDiscountFlag.noListPrice:
      case QuoteDiscountFlag.invalid:
        error = QuoteFinanceLineError.dealPrice;
    }
  }

  /// 用户改了折扣(仅按标价打折行)。
  void onDiscountChanged(String text) {
    if (!discountEditable) return;
    if (!isMaster) directPricing = true;
    if (!isValidQuoteDiscount(text)) {
      error = QuoteFinanceLineError.discount;
      return;
    }
    deal.text =
        quoteDealPriceFromDiscount(
          directPricing ? price.text : listPrice,
          text.trim(),
        ) ??
        '';
    error = null;
  }

  /// 改回按标价打折(有标价才可)：折扣优先按当前成交单价反推，推不出用原折扣。
  void useMasterPricing() {
    if (!hasListPrice) return;
    directPricing = false;
    price.text = listPrice ?? '';
    source = QuotePriceSource.master;
    final derived = quoteDiscountFromDealPrice(deal.text, listPrice);
    final rate = derived.hasDiscount
        ? derived.discount!
        : (line.isFinancePriced
              ? '1.0000'
              : (normalizeQuoteDiscount(line.discount) ?? '1.0000'));
    discount.text = financeTrim(rate);
    deal.text = quoteDealPriceFromDiscount(listPrice, rate) ?? '';
    error = null;
  }

  /// 设为赠品/0价(财务定价 0)。
  void markGiveaway() {
    directPricing = false;
    price.text = '0';
    refreshing = false;
    source = QuotePriceSource.finance;
    deal.text = '0';
    discount.text = '1';
    error = null;
  }

  /// 按货品资料最新标价刷新(折扣不变)；只对冻结标价已过时的行有效。
  void refreshFromMaster() {
    if (!line.canRefreshFromMaster) return;
    directPricing = false;
    price.text = line.currentMasterPrice ?? '';
    refreshing = true;
    source = QuotePriceSource.master;
    discount.text = financeTrim(_initialDiscount);
    deal.text =
        quoteDealPriceFromDiscount(line.currentMasterPrice, _initialDiscount) ??
        '';
    error = null;
  }

  /// 撤销本行修改。
  void restore() {
    removed = false;
    directPricing = line.isFinancePriced && !sameDecimal(_initialDiscount, '1');
    qty.text = line.qty ?? '';
    price.text = line.storedPrice ?? '';
    refreshing = false;
    source = _initialSource;
    deal.text = _initialDeal;
    discount.text = financeTrim(_initialDiscount);
    error = null;
  }

  /// 保存请求的一行；没改或不合法时返回 null(页面先挡不合法行)。
  void onPriceChanged(String text) {
    if (!priceEditable) return;
    directPricing = true;
    error = null;
    deal.text = quoteDealPriceFromDiscount(text, discount.text) ?? '';
  }

  SalesQuoteFinanceLineEdit? toEdit() {
    if (!dirty || !valid) return null;
    if (removed) return SalesQuoteFinanceLineEdit.remove(itemId: itemId);
    final quantity = sameDecimal(qty.text, line.qty) ? null : qty.text.trim();
    if (directPricing) {
      return SalesQuoteFinanceLineEdit.commercial(
        itemId: itemId,
        qty: quantity,
        price: price.text.trim(),
        discount: normalizeQuoteDiscount(discount.text),
      );
    }
    if (quantity != null &&
        _sameDeal(deal.text, _initialDeal) &&
        sameDecimal(discount.text, _initialDiscount) &&
        source == _initialSource &&
        !refreshing) {
      return SalesQuoteFinanceLineEdit.commercial(
        itemId: itemId,
        qty: quantity,
      );
    }
    if (refreshing) {
      return SalesQuoteFinanceLineEdit.useMasterPrice(
        itemId: itemId,
        qty: quantity,
      );
    }
    if (isMaster) {
      // 冻结标价在用: 直接核定折扣; 否则(没单价 / 原为财务定价)提交成交单价,
      // 服务端按同一个标价反推出同一个折扣并改回按标价打折。
      if (line.pricedFromFrozenList) {
        return SalesQuoteFinanceLineEdit.discount(
          itemId: itemId,
          qty: quantity,
          discount: normalizeQuoteDiscount(discount.text)!,
        );
      }
      return SalesQuoteFinanceLineEdit.dealPrice(
        itemId: itemId,
        qty: quantity,
        dealPrice: financeTrim(deal.text),
      );
    }
    if (isZeroDecimal(deal.text)) {
      return SalesQuoteFinanceLineEdit.giftZeroPrice(
        itemId: itemId,
        qty: quantity,
      );
    }
    return SalesQuoteFinanceLineEdit.dealPrice(
      itemId: itemId,
      qty: quantity,
      dealPrice: financeTrim(deal.text),
    );
  }

  void dispose() {
    qty.dispose();
    price.dispose();
    deal.dispose();
    discount.dispose();
  }

  static bool _sameDeal(String now, String initial) {
    final a = now.trim();
    final b = initial.trim();
    if (a.isEmpty || b.isEmpty) return a == b;
    return sameDecimal(a, b);
  }

  static String? _nonEmpty(String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// 十进制原文去掉末尾多余的 0(不四舍五入)；空返回 ''。
String financeTrim(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return '';
  if (!text.contains('.')) return text;
  var out = text;
  while (out.endsWith('0')) {
    out = out.substring(0, out.length - 1);
  }
  return out.endsWith('.') ? out.substring(0, out.length - 1) : out;
}
