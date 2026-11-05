import 'dart:collection';
import 'dart:convert';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/platform_tables/platform_table_row.dart';
import '../config/finance_doc_config.dart';
import '../providers/finance_name_provider.dart';
import '../widgets/finance_grid_columns.dart';
import 'finance_decimal.dart';
import 'finance_doc.dart';

class FinanceEntryError implements Exception {
  const FinanceEntryError(this.message, this.column);
  final String message;
  final String column;
}

/// Mirrors the server's grouping header, for preview only.
String financeEntryGroupKey(Map<String, dynamic> body) {
  final header = SplayTreeMap<String, dynamic>.from(body)
    ..removeWhere(
      (key, _) => const {
        'items',
        'createIdempotencyKey',
        'amountOriginal',
        'accountAmount',
        'bankFeeAccountAmount',
        'otherFeeAccountAmount',
      }.contains(key),
    );
  if (header.containsKey('receiptKind') &&
      header['feeSettlementMode'] == 'NONE') {
    header['feeSettlementMode'] = 'DEDUCTED_FROM_PROCEEDS';
    header['feeBearer'] = 'COMPANY';
  }
  final selectedOrders = <String>{
    for (final item in body['items'] as List? ?? const [])
      if (item is Map &&
          item['requestedSalesOrderId'] is String &&
          (item['requestedSalesOrderId'] as String).trim().isNotEmpty)
        (item['requestedSalesOrderId'] as String).trim().toLowerCase(),
  }.toList()..sort();
  return '${jsonEncode(header)}${selectedOrders.isEmpty ? '' : '|order-sources:${jsonEncode(selectedOrders)}'}';
}

/// Raw decimal text is submitted unchanged; server services own accounting.
Map<String, dynamic> financeEntryRequest(
  FinanceGridRow row, {
  required FinanceDocConfig config,
  required FinanceNameService names,
  required String billDate,
  required String commandKey,
  String? operatorId,
  String? remark,
  bool requireMethod = false,
}) {
  final terms = row.entry;
  Never fail(String message, String column) =>
      throw FinanceEntryError(message, column);
  String positive(String value, String label, String column) {
    final units = financeAmountUnits(value.trim());
    if (units == null || units <= BigInt.zero) {
      fail('$label须大于 0，最多 24 位小数', column);
    }
    return value.trim();
  }

  if (terms.accountId == null) {
    fail('请选择${config.accountLabel}', 'entryAccount');
  }
  if (config.hasParty && terms.partyId == null) {
    fail('请选择${config.partyLabel}', 'entryParty');
  }
  if (!config.isTransfer && requireMethod && terms.methodId == null) {
    fail('请选择收付款方式', 'entryMethod');
  }
  if (terms.currencyId == null) fail('请选择币种', 'entryCurrency');
  final rate = names.currencyIsBase(terms.currencyId) == true
      ? '1'
      : financeExactTrimmed(row.exchangeRate.text) ??
            row.exchangeRate.text.trim();
  final rateUnits = financeExactDecimalUnits(rate, scale: 6);
  if (rateUnits == null || rateUnits <= BigInt.zero) {
    fail('汇率须大于 0，最多 6 位小数', 'exchangeRate');
  }
  final amount = positive(row.amount.text, config.amountLabel, 'amount');
  if (config.isAllocate && row.pricing?.error.value != null) {
    fail(row.pricing!.error.value!, 'amount');
  }
  final item = <String, dynamic>{'amountOriginal': amount};
  if (config.isSettle && terms.receiptKind != 'CUSTOMER_PREPAYMENT') {
    if (row.appliedLedgerId == null) {
      fail('请引用${config.isClient ? '应收' : '应付'}单据', 'entrySource');
    }
    if (row.currencyId != terms.currencyId) {
      fail('币种必须与引用单据一致', 'entryCurrency');
    }
    item.addAll({
      'appliedLedgerId': row.appliedLedgerId,
      if (config.isClient && row.requestedSalesOrderId != null)
        'requestedSalesOrderId': row.requestedSalesOrderId,
      'appliedBillNo': row.appliedBillNo,
      if (config.isClient) 'clientId': terms.partyId,
      if (config.isClient) 'currencyId': terms.currencyId,
      if (config.isClient) 'exchangeRate': rate,
      if (config.isClient) 'writeOffAmount': '0',
    });
  } else if (config.isAllocate) {
    if (row.styleId == null) {
      fail(
        '请选择${config.type == FinanceDocType.expense ? '费用' : '收入'}项目',
        'style',
      );
    }
    item.addAll({
      config.type == FinanceDocType.expense
              ? 'expenseStyleId'
              : 'incomeStyleId':
          row.styleId,
      if (row.department.text.isNotEmpty) 'departmentId': row.department.text,
      if (row.qty.text.isNotEmpty) 'qty': row.qty.text,
      if (row.price.text.isNotEmpty) 'price': row.price.text,
      ...platformRowPayload(row),
    });
  } else if (config.isTransfer) {
    if (row.inAccountId == null) fail('请选择转入账户', 'inAccount');
    if (row.inAccountId == terms.accountId) fail('转入账户不能与转出账户相同', 'inAccount');
    item.addAll({
      'inAccountId': row.inAccountId,
      'occurDate': row.occurDate ?? billDate,
    });
  }
  item[config.isTransfer ? 'summary' : 'remark'] = row.remark.text.trim();
  final body = <String, dynamic>{
    'billDate': billDate,
    config.isTransfer ? 'outAccountId' : 'accountId': terms.accountId,
    'currencyId': terms.currencyId,
    'exchangeRate': rate,
    'operatorId': ?operatorId,
    'remark': remark,
    if (config.hasParty)
      config.isClient ? 'clientId' : 'supplierId': terms.partyId,
    if (!config.isTransfer && terms.methodId != null)
      config.isClient || config.type == FinanceDocType.otherIncome
              ? 'receiptMethodId'
              : 'paymentMethodId':
          terms.methodId,
    'items': [item],
  };
  if (!config.isSettle) return body;
  final accountCurrency = names.accountCurrencyId(terms.accountId);
  if (names.accountLoadError != null ||
      accountCurrency == null ||
      names.accountStatus(terms.accountId) != '使用') {
    fail('账户未加载、已停用或缺少币种，请刷新账户资料', 'entryAccount');
  }
  final same = accountCurrency == terms.currencyId;
  if (!same && names.accountIsBaseCurrency(terms.accountId) != true) {
    fail('账户必须为人民币账户或与货款原币相同', 'entryAccount');
  }
  final fee = financeAmountUnits(
    terms.fee.text.trim().isEmpty ? '0' : terms.fee.text.trim(),
  );
  if (fee == null || fee < BigInt.zero) fail('结算费用不能为负数，最多 24 位小数', 'entryFee');
  final amountUnits = financeAmountUnits(amount)!;
  final feeMode = fee == BigInt.zero
      ? 'NONE'
      : terms.feeMode == 'NONE'
      ? 'DEDUCTED_FROM_PROCEEDS'
      : terms.feeMode;
  final expected = config.isSupplier
      ? amountUnits + fee
      : amountUnits - (feeMode == 'DEDUCTED_FROM_PROCEEDS' ? fee : BigInt.zero);
  final actualText = terms.accountAmount.text.trim().isEmpty && same
      ? financeAmountFromUnits(expected)
      : terms.accountAmount.text.trim();
  final actual = financeAmountUnits(
    positive(
      actualText,
      '账户实际${config.isSupplier ? '扣款' : '入账'}',
      'entryAccountAmount',
    ),
  )!;
  if (same && actual != expected) {
    fail('同币种实际金额与货款、费用不一致，请核对', 'entryAccountAmount');
  }
  if (config.isSupplier && fee >= actual) fail('结算费用须小于实际扣款', 'entryFee');
  body.addAll({
    'createIdempotencyKey': commandKey,
    'accountCurrencyId': accountCurrency,
    'accountAmount': actualText,
    'bankFeeAccountAmount': financeAmountFromUnits(fee),
    'bankReference': terms.bankReference.text.trim().isEmpty
        ? null
        : terms.bankReference.text.trim(),
    'bankBookedAt': ChinaDateTime.wallTimeToUtc(
      terms.bookedAt,
    ).toIso8601String(),
  });
  if (config.isSupplier) return body;
  final prepayment = terms.receiptKind == 'CUSTOMER_PREPAYMENT';
  if (prepayment && terms.salesOrderId == null) {
    fail('请选择已审核的销售订单', 'entrySource');
  }
  if (prepayment && row.appliedLedgerId != null) {
    fail('订单预收不能同时引用应收', 'entrySource');
  }
  final agent = terms.channel == 'TRADE_AGENT_CONVERSION';
  if (agent &&
      (same ||
          names.accountIsBaseCurrency(terms.accountId) != true ||
          terms.agentId == null ||
          terms.agentStatement.text.trim().isEmpty)) {
    fail('外贸代理结汇须选择代理、人民币账户并填写结算单号', 'entrySettings');
  }
  if (feeMode == 'PAID_SEPARATELY' && terms.feeAccountId == null) {
    fail('费用另付须选择费用付款账户', 'entrySettings');
  }
  final legacyOther =
      financeAmountUnits(terms.legacyOtherFee ?? '0') ?? BigInt.zero;
  if (legacyOther > fee) fail('恢复草稿的费用拆分超过结算费用，请核对', 'entryFee');
  body.addAll({
    'receiptKind': terms.receiptKind,
    if (prepayment) 'salesOrderId': terms.salesOrderId,
    if (prepayment) 'items': <Map<String, dynamic>>[],
    'amountOriginal': amount,
    'settlementChannel': terms.channel,
    'settlementAgentSupplierId': agent ? terms.agentId : null,
    'agentStatementNo': agent ? terms.agentStatement.text.trim() : null,
    'exchangeRateSource': agent ? 'TRADE_AGENT_STATEMENT' : 'BANK_STATEMENT',
    'exchangeRateEffectiveAt': ChinaDateTime.wallTimeToUtc(
      terms.rateEffectiveAt,
    ).toIso8601String(),
    'bankFeeAccountAmount': financeAmountFromUnits(fee - legacyOther),
    'otherFeeAccountAmount': financeAmountFromUnits(legacyOther),
    if (legacyOther > BigInt.zero)
      'otherFeeStyleId': terms.legacyOtherFeeStyleId,
    'feeSettlementMode': feeMode,
    'feeBearer': fee == BigInt.zero ? 'NONE' : 'COMPANY',
    'feePaymentAccountId': feeMode == 'PAID_SEPARATELY'
        ? terms.feeAccountId
        : null,
  });
  return body;
}
