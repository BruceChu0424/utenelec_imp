// 报价核价行编辑状态(ADR-134)：成交单价 ↔ 折扣联动；定价来源由成交单价自动决定
// (低于标价 = 折扣，没有标价或高于标价 = 财务定价，SPEC §6.2)；赠品/0价；按最新标价刷新；
// 撤销与保存请求(服务端 QuoteFinanceEditRequest.Line 四选一)；以及「还不能确认」的判定。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/models/quote_finance_line_draft.dart';
import 'package:uten_imp/features/finance/models/quote_finance_pricing.dart';
import 'package:uten_imp/features/finance/models/sales_quote_finance_review.dart';

/// 与服务端 QuoteFinanceReviewDto.Line 同义：[stored] = 服务端字段 listPrice(本行已存单价)。
SalesQuoteFinanceLine _line({
  String? stored = '100',
  String? currentMaster = '100',
  String priceSource = QuotePriceSource.master,
  String? discount = '1',
  String? clientPrice,
  String? lastConfirmed,
  String? blockingReason,
}) {
  // 服务端: dealPrice = 单价 × 折扣, amount = 数量 × 单价 × 折扣(财务定价行折扣 1)。
  final rate = priceSource == QuotePriceSource.finance ? '1' : discount ?? '1';
  final deal = quoteDealPriceFromDiscount(stored, rate);
  final amount = quoteLineAmountPreview(
    qty: '3',
    price: stored,
    discount: rate,
  );
  return SalesQuoteFinanceLine(
    itemId: 'line-1',
    qty: '3',
    storedPrice: stored,
    currentMasterPrice: currentMaster,
    priceSource: priceSource,
    discount: discount,
    dealPrice: deal,
    amount: amount,
    clientPrice: clientPrice,
    clientPriceLocal: clientPrice,
    lastFinanceConfirmedDiscount: lastConfirmed,
    blockingReason: blockingReason,
  );
}

void main() {
  test(
    'finance can change base price, quantity and discount without mutating master reference',
    () {
      final draft = QuoteFinanceLineDraft(
        _line(priceSource: QuotePriceSource.sales),
      );
      addTearDown(draft.dispose);
      draft.price.text = '80.25';
      draft.onPriceChanged('80.25');
      draft.qty.text = '4';
      draft.discount.text = '0.9';
      draft.onDiscountChanged('0.9');
      expect(draft.line.currentMasterPrice, '100');
      expect(draft.amountPreview, '288.9');
      expect(draft.toEdit()!.toJson(), {
        'itemId': 'line-1',
        'qty': '4',
        'price': '80.25',
        'discount': '0.9000',
      });
      draft.removed = true;
      expect(draft.amountPreview, '0');
      expect(draft.toEdit()!.toJson(), {'itemId': 'line-1', 'removed': true});
      draft.restore();
      expect(draft.qty.text, '3');
      expect(draft.price.text, '100');
      expect(draft.dirty, isFalse);
    },
  );

  test(
    'quantity-only edits preserve server prices; zero quantity never masquerades as deletion',
    () {
      final draft = QuoteFinanceLineDraft(_line(discount: '0.85'));
      addTearDown(draft.dispose);
      draft.qty.text = '4';
      expect(draft.toEdit()!.toJson(), {'itemId': 'line-1', 'qty': '4'});
      draft.qty.text = '0';
      expect(draft.valid, isFalse);
      expect(draft.error, QuoteFinanceLineError.quantity);
      expect(draft.toEdit(), isNull);
    },
  );

  test('frozen list price: deal price derives a 4-place discount', () {
    final draft = QuoteFinanceLineDraft(_line());
    expect(draft.deal.text, '100');
    expect(draft.discount.text, '1');
    expect(draft.dirty, isFalse);

    draft.deal.text = '95';
    draft.onDealChanged('95');
    expect(draft.discount.text, '0.95');
    expect(draft.source, QuotePriceSource.master);
    expect(draft.error, isNull);
    expect(draft.dirty, isTrue);
    expect(draft.amountPreview, '285');
    expect(draft.toEdit()!.toJson(), {
      'itemId': 'line-1',
      'discount': '0.9500',
    });
  });

  test('discount derives the deal price', () {
    final draft = QuoteFinanceLineDraft(_line());
    draft.discount.text = '0.9';
    draft.onDiscountChanged('0.9');
    expect(draft.deal.text, '90');
    expect(draft.error, isNull);
    expect(draft.toEdit()!.discount, '0.9000');
  });

  test('a row with an input error counts as changed and blocks saving', () {
    final draft = QuoteFinanceLineDraft(_line());
    draft.discount.text = '1.2';
    draft.onDiscountChanged('1.2');
    expect(draft.error, QuoteFinanceLineError.discount);
    expect(draft.dirty, isTrue, reason: 'never silently dropped on save');
    expect(draft.valid, isFalse);
    expect(draft.toEdit(), isNull);
    expect(draft.deal.text, '100');

    final zero = QuoteFinanceLineDraft(_line());
    zero.deal.text = '0';
    zero.onDealChanged('0');
    expect(zero.error, QuoteFinanceLineError.dealPrice);
    expect(zero.dirty, isTrue);
  });

  test('above list switches to a finance price instead of a dead end', () {
    final draft = QuoteFinanceLineDraft(_line());
    draft.deal.text = '120';
    draft.onDealChanged('120');
    expect(draft.error, isNull);
    expect(draft.source, QuotePriceSource.finance);
    expect(draft.aboveList, isTrue);
    expect(draft.discount.text, '1');
    expect(draft.amountPreview, '360');
    expect(draft.toEdit()!.toJson(), {'itemId': 'line-1', 'dealPrice': '120'});

    // 再改回低于标价：自动回到按标价打折，折扣看得见。
    draft.deal.text = '80';
    draft.onDealChanged('80');
    expect(draft.source, QuotePriceSource.master);
    expect(draft.aboveList, isFalse);
    expect(draft.discount.text, '0.8');
    expect(draft.toEdit()!.toJson(), {
      'itemId': 'line-1',
      'discount': '0.8000',
    });
  });

  test('below-list prices never become a finance price', () {
    final draft = QuoteFinanceLineDraft(_line());
    for (final price in ['99.99', '1', '50']) {
      draft.deal.text = price;
      draft.onDealChanged(price);
      expect(draft.source, QuotePriceSource.master, reason: price);
      expect(draft.toEdit()!.discount, isNotNull, reason: price);
      expect(draft.toEdit()!.dealPrice, isNull, reason: price);
    }
  });

  test('back to list pricing from above list keeps the original discount', () {
    final draft = QuoteFinanceLineDraft(_line(discount: '0.9'));
    draft.deal.text = '130';
    draft.onDealChanged('130');
    expect(draft.source, QuotePriceSource.finance);
    draft.useMasterPricing();
    expect(draft.source, QuotePriceSource.master);
    expect(draft.discount.text, '0.9');
    expect(draft.deal.text, '90');
    expect(draft.dirty, isFalse);
  });

  test(
    'a finance-priced line below the current list price turns into a '
    'discount via dealPrice (server derives against the same list price)',
    () {
      final draft = QuoteFinanceLineDraft(
        _line(stored: '130', priceSource: QuotePriceSource.finance),
      );
      expect(draft.listPrice, '100');
      expect(draft.aboveList, isTrue);
      expect(draft.dirty, isFalse);
      draft.deal.text = '90';
      draft.onDealChanged('90');
      expect(draft.source, QuotePriceSource.master);
      expect(draft.discount.text, '0.9');
      expect(draft.toEdit()!.toJson(), {'itemId': 'line-1', 'dealPrice': '90'});
    },
  );

  test('no list price: only finance pricing, empty means unpriced', () {
    final draft = QuoteFinanceLineDraft(
      _line(stored: null, currentMaster: null),
    );
    expect(draft.forcedFinance, isTrue);
    expect(draft.discountEditable, isFalse);
    expect(draft.unpriced, isTrue);
    expect(draft.dirty, isFalse);

    draft.deal.text = '12.50';
    draft.onDealChanged('12.50');
    expect(draft.source, QuotePriceSource.finance);
    expect(draft.unpriced, isFalse);
    expect(draft.toEdit()!.toJson(), {'itemId': 'line-1', 'dealPrice': '12.5'});

    // 本来没有单价的行清空 = 回到原样，不算填错。
    draft.deal.text = '';
    draft.onDealChanged('');
    expect(draft.error, isNull);
    expect(draft.dirty, isFalse);
    expect(draft.toEdit(), isNull);

    // 已有财务价的行清空 = 填错(要么填价格，要么撤销本行修改)。
    final priced = QuoteFinanceLineDraft(
      _line(
        stored: '12.5',
        currentMaster: null,
        priceSource: QuotePriceSource.finance,
      ),
    );
    priced.deal.text = '';
    priced.onDealChanged('');
    expect(priced.error, QuoteFinanceLineError.needPrice);
    expect(priced.dirty, isTrue);
    expect(priced.toEdit(), isNull);
  });

  test('no stored price but the goods now has a list price: priced by discount '
      'through dealPrice', () {
    final draft = QuoteFinanceLineDraft(_line(stored: null, discount: '0.95'));
    expect(draft.hasListPrice, isTrue);
    expect(draft.deal.text, isEmpty);
    expect(draft.unpriced, isTrue, reason: 'server still has no price');
    draft.discount.text = '0.95';
    draft.onDiscountChanged('0.95');
    expect(draft.deal.text, '95');
    expect(draft.dirty, isTrue);
    expect(draft.toEdit()!.toJson(), {'itemId': 'line-1', 'dealPrice': '95'});
  });

  test('giveaway is an explicit finance zero price', () {
    final draft = QuoteFinanceLineDraft(
      _line(stored: '0', currentMaster: '0', clientPrice: '5'),
    );
    expect(draft.line.needsFinancePrice, isTrue);
    expect(draft.dirty, isFalse);
    expect(draft.isGiveaway, isFalse, reason: 'master zero is not a giveaway');

    draft.markGiveaway();
    expect(draft.isGiveaway, isTrue);
    expect(draft.dirty, isTrue, reason: 'MASTER 0 → FINANCE 0 is a change');
    expect(draft.toEdit()!.toJson(), {
      'itemId': 'line-1',
      'giftZeroPrice': true,
    });

    draft.restore();
    expect(draft.dirty, isFalse);
    expect(draft.source, QuotePriceSource.master);
  });

  test('refresh from the latest list price keeps the discount', () {
    final line = _line(currentMaster: '120', discount: '0.9');
    expect(line.canRefreshFromMaster, isTrue);
    final draft = QuoteFinanceLineDraft(line);
    draft.refreshFromMaster();
    expect(draft.refreshing, isTrue);
    expect(draft.listPrice, '120');
    expect(draft.deal.text, '108');
    expect(draft.discount.text, '0.9');
    expect(draft.priceEditable, isFalse);
    expect(draft.discountEditable, isFalse);
    expect(draft.amountPreview, '324');
    expect(draft.toEdit()!.toJson(), {
      'itemId': 'line-1',
      'useMasterPrice': true,
    });
    draft.restore();
    expect(draft.dirty, isFalse);
    expect(_line().canRefreshFromMaster, isFalse, reason: 'same list price');
  });

  test(
    'highlights lines whose discount differs from the last confirmation',
    () {
      final same = QuoteFinanceLineDraft(
        _line(discount: '0.95', lastConfirmed: '0.9500'),
      );
      expect(same.differsFromLastConfirmed, isFalse);
      final changed = QuoteFinanceLineDraft(
        _line(discount: '0.9', lastConfirmed: '0.95'),
      );
      expect(changed.differsFromLastConfirmed, isTrue);
    },
  );

  test('file difference compares with the converted file price', () {
    final draft = QuoteFinanceLineDraft(_line(clientPrice: '95'));
    expect(draft.fileDifference, '15');
    draft.deal.text = '95';
    draft.onDealChanged('95');
    expect(draft.fileDifference, '0');
  });

  test('server-side confirm gate: needsFinancePrice (exact decimals)', () {
    expect(_line(stored: null).needsFinancePrice, isTrue);
    expect(_line(stored: '0', clientPrice: '5').needsFinancePrice, isTrue);
    expect(
      _line(
        stored: '0.00',
        priceSource: QuotePriceSource.finance,
        clientPrice: '5',
      ).needsFinancePrice,
      isFalse,
      reason: 'finance ticked 赠品/0价',
    );
    expect(
      _line(stored: '0').needsFinancePrice,
      isFalse,
      reason: 'zero master price without a file price is allowed',
    );
    expect(_line(stored: '0', clientPrice: '0.00').needsFinancePrice, isFalse);
    expect(_line().needsFinancePrice, isFalse);
    expect(
      _line(blockingReason: '还没有单价, 请先填写成交单价').needsFinancePrice,
      isTrue,
      reason: 'the server reason wins',
    );
    expect(_line(stored: '0.0001').hasListPrice, isTrue);
    expect(_line(stored: '0.0000').hasListPrice, isFalse);
  });

  test('financeTrim drops trailing zeros only', () {
    expect(financeTrim('0.9500'), '0.95');
    expect(financeTrim('100'), '100');
    expect(financeTrim('1.0000'), '1');
    expect(financeTrim(null), '');
  });
}
