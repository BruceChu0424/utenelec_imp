// 钱流单据统一模型（5 单据超集，对应后端各 *ListItem/*Detail/*ItemDto）。
//
// 5 单据差异由 doc_type 决定可选字段是否非空：
// - receipt（销售收款）：clientId + items=AR 核销行（appliedLedgerId）
// - payment（采购付款）：supplierId + items=AP 核销行（appliedLedgerId）
// - expense（一般费用）：accountId + items=分摊行（expenseStyleId + departmentId）
// - otherIncome（其它收入）：accountId + items=分摊行（incomeStyleId + departmentId）
// - bankTransfer（银行存取款）：outAccountId + items=转入行（inAccountId + occurDate）
// 一个超集模型 ×5 配置，避免 5 套重复。关系 UUID=String；日期=ISO 字符串。
// 金额在服务端/数据库保持 BigDecimal/NUMERIC 以支持精确核算、汇总和约束；前端仅按 num 解析显示，
// 金额不做会破坏这些能力的字段级随机加密，静态数据由磁盘/备份分层加密保护。
//
// 端点路径常量化在 finance_repository.dart 顶部（暂不进 api_endpoints.dart）。

import 'package:flutter/material.dart';

/// 钱流单据类型。pathSegment 对齐后端 /api/finance/{receipts|payments|expenses|incomes|bank-transfers}。
enum FinanceDocType {
  receipt('receipts'),
  payment('payments'),
  expense('expenses'),
  otherIncome('incomes'),
  bankTransfer('bank-transfers');

  const FinanceDocType(this.pathSegment);
  final String pathSegment;

  static FinanceDocType? tryByPath(String seg) {
    for (final type in FinanceDocType.values) {
      if (type.pathSegment == seg) return type;
    }
    return null;
  }

  static FinanceDocType byPath(String seg) =>
      tryByPath(seg) ?? (throw ArgumentError.value(seg, 'seg', '未知钱流单据路由段'));
}

/// 单据状态：0草稿 / 1已审 / -1红冲（与采购/库存对齐）。
const int kFinanceStatusDraft = 0;
const int kFinanceStatusApproved = 1;
const int kFinanceStatusReversed = -1;

String financeStatusLabel(int? code) {
  switch (code) {
    case kFinanceStatusDraft:
      return '草稿';
    case kFinanceStatusApproved:
      return '已审';
    case kFinanceStatusReversed:
      return '红冲';
    default:
      return '—';
  }
}

String? financeDecimalText(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

double? _financeDecimalDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

String financeReceiptKindLabel(String? value) => switch (value?.toUpperCase()) {
  'AR_SETTLEMENT' => '普通应收收款',
  'CUSTOMER_PREPAYMENT' => '客户订单预收',
  _ => value?.trim().isNotEmpty == true ? value! : '未标记',
};

String financeArApSourceTypeLabel(String? value) =>
    switch (value?.toUpperCase()) {
      'SALES_SHIPMENT' => '销售发运',
      'SALES_RETURN' => '销售退货',
      'DIRECT_RECEIPT' => '财务直接预收',
      'PURCHASE_RECEIPT' => '采购收货',
      'PURCHASE_RETURN' => '采购退货',
      'SUBCONTRACT_RECEIPT' => '委外进仓',
      'SUBCONTRACT_RETURN' => '委外退货',
      'SUBCONTRACT_WASTE' || 'SUBCONTRACT_WASTE_DEDUCTION' => '委外损耗扣款',
      'OPENING_BALANCE' => '期初余额',
      'MANUAL' || 'MANUAL_AR' || 'MANUAL_AP' => '手工立账',
      _ => value?.trim().isNotEmpty == true ? value! : '—',
    };

String financeArApOpenItemKindLabel(String? value) =>
    switch (value?.toUpperCase()) {
      'CUSTOMER_PREPAYMENT' => '客户预收',
      'RECEIVABLE' => '客户应收',
      'PAYABLE' => '供应商应付',
      'CREDIT' || 'CLAIM_CREDIT' => '供应商贷项',
      'PREPAYMENT' => '供应商预付款',
      _ => value?.trim().isNotEmpty == true ? value! : '—',
    };

/// 状态对应的主题色（徽章用）。
Color financeStatusColor(int? code, ThemeData theme) {
  switch (code) {
    case kFinanceStatusDraft:
      return theme.colorScheme.onSurfaceVariant;
    case kFinanceStatusApproved:
      return Colors.green;
    case kFinanceStatusReversed:
      return theme.colorScheme.error;
    default:
      return theme.colorScheme.onSurfaceVariant;
  }
}

// ===== 5 单据列表项（超集：partyId 在 receipt 取 clientId、payment 取 supplierId）=====

class FinanceDocListItem {
  const FinanceDocListItem({
    required this.id,
    this.billNo,
    this.billDate,
    this.receiptKind,
    this.salesOrderId,
    this.partyId,
    this.accountId,
    this.outAccountId,
    this.amountLocal,
    this.amountLocalText,
    this.status,
    this.legacyId,
  });

  final String id;
  final String? billNo;
  final String? billDate;
  final String? receiptKind;
  final String? salesOrderId;
  final String? partyId; // receipt→clientId / payment→supplierId；其它=null
  final String? accountId;
  final String? outAccountId; // bankTransfer 用
  final double? amountLocal;
  final String? amountLocalText;
  final int? status;
  final int? legacyId;

  factory FinanceDocListItem.fromJson(Map<String, dynamic> json) =>
      FinanceDocListItem(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        receiptKind: json['receiptKind'] as String?,
        salesOrderId: json['salesOrderId'] as String?,
        // receipt 用 clientId、payment 用 supplierId、其余无 party。
        partyId: (json['clientId'] ?? json['supplierId']) as String?,
        accountId: (json['accountId'] ?? json['outAccountId']) as String?,
        outAccountId: json['outAccountId'] as String?,
        amountLocal: (json['amountLocal'] as num?)?.toDouble(),
        amountLocalText: financeDecimalText(
          json['amountLocalExact'] ?? json['amountLocal'],
        ),
        status: (json['status'] as num?)?.toInt(),
        legacyId: (json['legacyId'] as num?)?.toInt(),
      );
}

// ===== 5 单据明细行（超集）=====

class FinanceDocItem {
  const FinanceDocItem({
    this.id,
    this.lineNo,
    this.appliedLedgerId,
    this.appliedBillNo,
    this.partyId,
    this.salesOrderId,
    this.expenseStyleId,
    this.incomeStyleId,
    this.departmentId,
    this.counterpartAccountId,
    this.counterpartName,
    this.inAccountId,
    this.occurDate,
    this.qty,
    this.qtyText,
    this.price,
    this.priceText,
    this.amountOriginal,
    this.amountOriginalText,
    this.amountLocal,
    this.amountLocalText,
    this.currencyId,
    this.exchangeRate,
    this.exchangeRateText,
    this.writeOffAmount,
    this.writeOffAmountText,
    this.writeOffLocal,
    this.writeOffLocalText,
    this.appliedAmountLocal,
    this.appliedAmountLocalText,
    this.balanceBeforeOriginal,
    this.balanceBeforeOriginalText,
    this.balanceAfterOriginal,
    this.balanceAfterOriginalText,
    this.exchangeDiff,
    this.exchangeDiffText,
    this.summary,
    this.remark,
  });

  final String? id;
  final int? lineNo;
  // receipt/payment 核销
  final String? appliedLedgerId;
  final String? appliedBillNo;
  final String? partyId;
  final String? salesOrderId;
  // expense/otherIncome 分摊
  final String? expenseStyleId;
  final String? incomeStyleId;
  final String? departmentId;
  // bankTransfer 转入
  final String? inAccountId;
  final String? occurDate;
  // 公共
  final String? counterpartAccountId;
  final String? counterpartName;
  final double? qty;
  final String? qtyText;
  final double? price;
  final String? priceText;
  final double? amountOriginal;
  final String? amountOriginalText;
  final double? amountLocal;
  final String? amountLocalText;
  final String? currencyId;
  final double? exchangeRate;
  final String? exchangeRateText;
  final double? writeOffAmount;
  final String? writeOffAmountText;
  final double? writeOffLocal;
  final String? writeOffLocalText;
  final double? appliedAmountLocal;
  final String? appliedAmountLocalText;
  final double? balanceBeforeOriginal;
  final String? balanceBeforeOriginalText;
  final double? balanceAfterOriginal;
  final String? balanceAfterOriginalText;
  final double? exchangeDiff;
  final String? exchangeDiffText;
  final String? summary;
  final String? remark;

  factory FinanceDocItem.fromJson(Map<String, dynamic> json) => FinanceDocItem(
    id: json['id'] as String?,
    lineNo: (json['lineNo'] as num?)?.toInt(),
    appliedLedgerId: json['appliedLedgerId'] as String?,
    appliedBillNo: json['appliedBillNo'] as String?,
    partyId: (json['clientId'] ?? json['partyId']) as String?,
    salesOrderId: json['salesOrderId'] as String?,
    expenseStyleId: json['expenseStyleId'] as String?,
    incomeStyleId: json['incomeStyleId'] as String?,
    departmentId: json['departmentId'] as String?,
    counterpartAccountId: json['counterpartAccountId'] as String?,
    counterpartName: json['counterpartName'] as String?,
    inAccountId: json['inAccountId'] as String?,
    occurDate: json['occurDate'] as String?,
    qty: (json['qty'] as num?)?.toDouble(),
    qtyText: financeDecimalText(json['qtyExact'] ?? json['qty']),
    price: (json['price'] as num?)?.toDouble(),
    priceText: financeDecimalText(json['priceExact'] ?? json['price']),
    amountOriginal: (json['amountOriginal'] as num?)?.toDouble(),
    amountOriginalText: financeDecimalText(
      json['amountOriginalExact'] ?? json['amountOriginal'],
    ),
    amountLocal: (json['amountLocal'] as num?)?.toDouble(),
    amountLocalText: financeDecimalText(
      json['amountLocalExact'] ?? json['amountLocal'],
    ),
    currencyId: json['currencyId'] as String?,
    exchangeRate: (json['exchangeRate'] as num?)?.toDouble(),
    exchangeRateText: financeDecimalText(
      json['exchangeRateExact'] ?? json['exchangeRate'],
    ),
    writeOffAmount: (json['writeOffAmount'] as num?)?.toDouble(),
    writeOffAmountText: financeDecimalText(
      json['writeOffAmountExact'] ?? json['writeOffAmount'],
    ),
    writeOffLocal: (json['writeOffLocal'] as num?)?.toDouble(),
    writeOffLocalText: financeDecimalText(
      json['writeOffLocalExact'] ?? json['writeOffLocal'],
    ),
    appliedAmountLocal: (json['appliedAmountLocal'] as num?)?.toDouble(),
    appliedAmountLocalText: financeDecimalText(
      json['appliedAmountLocalExact'] ?? json['appliedAmountLocal'],
    ),
    balanceBeforeOriginal: (json['balanceBeforeOriginal'] as num?)?.toDouble(),
    balanceBeforeOriginalText: financeDecimalText(
      json['balanceBeforeOriginalExact'] ?? json['balanceBeforeOriginal'],
    ),
    balanceAfterOriginal: (json['balanceAfterOriginal'] as num?)?.toDouble(),
    balanceAfterOriginalText: financeDecimalText(
      json['balanceAfterOriginalExact'] ?? json['balanceAfterOriginal'],
    ),
    exchangeDiff: (json['exchangeDiff'] as num?)?.toDouble(),
    exchangeDiffText: financeDecimalText(
      json['exchangeDiffExact'] ?? json['exchangeDiff'],
    ),
    summary: json['summary'] as String?,
    remark: json['remark'] as String?,
  );
}

// ===== 5 单据详情（超集）=====

class FinanceDocDetail {
  const FinanceDocDetail({
    required this.id,
    this.version,
    this.legacyId,
    this.billNo,
    this.billDate,
    this.receiptKind,
    this.salesOrderId,
    this.clientId,
    this.supplierId,
    this.accountId,
    this.outAccountId,
    this.counterpartAccountId,
    this.currencyId,
    this.exchangeRate,
    this.exchangeRateText,
    this.amountOriginal,
    this.amountOriginalText,
    this.amountLocal,
    this.amountLocalText,
    this.bankFee,
    this.bankFeeText,
    this.otherFee,
    this.otherFeeText,
    this.settlementAuthorityVersion,
    this.createIdempotencyKey,
    this.settlementChannel,
    this.settlementAgentSupplierId,
    this.settlementAgentNameSnapshot,
    this.settlementRateQuoteDirection,
    this.exchangeRateSource,
    this.exchangeRateEffectiveAt,
    this.bankBookedAt,
    this.bankReference,
    this.agentStatementNo,
    this.accountCurrencyId,
    this.accountExchangeRate,
    this.accountExchangeRateText,
    this.accountExchangeRateSource,
    this.accountAmount,
    this.accountAmountText,
    this.accountAmountLocal,
    this.accountAmountLocalText,
    this.bankFeeAccountAmount,
    this.bankFeeAccountAmountText,
    this.otherFeeAccountAmount,
    this.otherFeeAccountAmountText,
    this.feeSettlementMode,
    this.feeBearer,
    this.feePaymentAccountId,
    this.feeAccountCurrencyId,
    this.feeAccountExchangeRate,
    this.feeAccountExchangeRateText,
    this.settlementGrossLocal,
    this.settlementGrossLocalText,
    this.otherFeeStyleId,
    this.receiptMethodId,
    this.paymentMethodId,
    this.invoiceNo,
    this.operatorId,
    this.makerId,
    this.approverId,
    this.makerName,
    this.createdAt,
    this.remark,
    this.status,
    this.closed = false,
    this.glStatus,
    this.items = const [],
  });

  final String id;
  final int? version;
  final int? legacyId;
  final String? billNo;
  final String? billDate;
  final String? receiptKind;
  final String? salesOrderId;
  final String? clientId;
  final String? supplierId;
  final String? accountId;
  final String? outAccountId;
  final String? counterpartAccountId;
  final String? currencyId;
  final double? exchangeRate;
  final String? exchangeRateText;
  final double? amountOriginal;
  final String? amountOriginalText;
  final double? amountLocal;
  final String? amountLocalText;
  final double? bankFee;
  final String? bankFeeText;
  final double? otherFee;
  final String? otherFeeText;

  /// 收款结算权威契约版本。null/0 表示历史 V0，1 表示到账与核销已分层。
  final int? settlementAuthorityVersion;
  final String? createIdempotencyKey;
  final String? settlementChannel;
  final String? settlementAgentSupplierId;
  final String? settlementAgentNameSnapshot;
  final String? settlementRateQuoteDirection;
  final String? exchangeRateSource;
  final String? exchangeRateEffectiveAt;
  final String? bankBookedAt;
  final String? bankReference;
  final String? agentStatementNo;
  final String? accountCurrencyId;
  final double? accountExchangeRate;
  final String? accountExchangeRateText;
  final String? accountExchangeRateSource;
  final double? accountAmount;
  final String? accountAmountText;
  final double? accountAmountLocal;
  final String? accountAmountLocalText;
  final double? bankFeeAccountAmount;
  final String? bankFeeAccountAmountText;
  final double? otherFeeAccountAmount;
  final String? otherFeeAccountAmountText;
  final String? feeSettlementMode;
  final String? feeBearer;
  final String? feePaymentAccountId;
  final String? feeAccountCurrencyId;
  final double? feeAccountExchangeRate;
  final String? feeAccountExchangeRateText;
  final double? settlementGrossLocal;
  final String? settlementGrossLocalText;
  final String? otherFeeStyleId;
  final String? receiptMethodId;
  final String? paymentMethodId;
  final String? invoiceNo;
  final String? operatorId;
  final String? makerId;
  final String? approverId;

  /// 制单员姓名（服务端解析；只读展示，不可修改）
  final String? makerName;

  /// 制单时间 ISO（审计 created_at，创建后不可变）
  final String? createdAt;
  final String? remark;
  final int? status;
  final bool closed;

  /// C6：0 未过账 / 1 已过账待确认 / 2 财务已确认（仅费用单）。
  final int? glStatus;
  final List<FinanceDocItem> items;

  factory FinanceDocDetail.fromJson(
    Map<String, dynamic> json,
  ) => FinanceDocDetail(
    id: json['id'] as String,
    version: (json['version'] as num?)?.toInt(),
    legacyId: (json['legacyId'] as num?)?.toInt(),
    billNo: json['billNo'] as String?,
    billDate: json['billDate'] as String?,
    receiptKind: json['receiptKind'] as String?,
    salesOrderId: json['salesOrderId'] as String?,
    clientId: json['clientId'] as String?,
    supplierId: json['supplierId'] as String?,
    accountId: json['accountId'] as String?,
    outAccountId: json['outAccountId'] as String?,
    counterpartAccountId: json['counterpartAccountId'] as String?,
    currencyId: json['currencyId'] as String?,
    exchangeRate: (json['exchangeRate'] as num?)?.toDouble(),
    exchangeRateText: financeDecimalText(
      json['exchangeRateExact'] ?? json['exchangeRate'],
    ),
    amountOriginal: (json['amountOriginal'] as num?)?.toDouble(),
    amountOriginalText: financeDecimalText(
      json['amountOriginalExact'] ?? json['amountOriginal'],
    ),
    amountLocal: (json['amountLocal'] as num?)?.toDouble(),
    amountLocalText: financeDecimalText(
      json['amountLocalExact'] ?? json['amountLocal'],
    ),
    bankFee: (json['bankFee'] as num?)?.toDouble(),
    bankFeeText: financeDecimalText(json['bankFeeExact'] ?? json['bankFee']),
    otherFee: (json['otherFee'] as num?)?.toDouble(),
    otherFeeText: financeDecimalText(json['otherFeeExact'] ?? json['otherFee']),
    settlementAuthorityVersion: (json['settlementAuthorityVersion'] as num?)
        ?.toInt(),
    createIdempotencyKey: json['createIdempotencyKey'] as String?,
    settlementChannel: json['settlementChannel'] as String?,
    settlementAgentSupplierId: json['settlementAgentSupplierId'] as String?,
    settlementAgentNameSnapshot: json['settlementAgentNameSnapshot'] as String?,
    settlementRateQuoteDirection:
        json['settlementRateQuoteDirection'] as String?,
    exchangeRateSource: json['exchangeRateSource'] as String?,
    exchangeRateEffectiveAt: json['exchangeRateEffectiveAt'] as String?,
    bankBookedAt: json['bankBookedAt'] as String?,
    bankReference: json['bankReference'] as String?,
    agentStatementNo: json['agentStatementNo'] as String?,
    accountCurrencyId: json['accountCurrencyId'] as String?,
    accountExchangeRate: _financeDecimalDouble(json['accountExchangeRate']),
    accountExchangeRateText: financeDecimalText(
      json['accountExchangeRateExact'] ?? json['accountExchangeRate'],
    ),
    accountExchangeRateSource: json['accountExchangeRateSource'] as String?,
    accountAmount: _financeDecimalDouble(json['accountAmount']),
    accountAmountText: financeDecimalText(
      json['accountAmountExact'] ?? json['accountAmount'],
    ),
    accountAmountLocal: _financeDecimalDouble(json['accountAmountLocal']),
    accountAmountLocalText: financeDecimalText(
      json['accountAmountLocalExact'] ?? json['accountAmountLocal'],
    ),
    bankFeeAccountAmount: _financeDecimalDouble(json['bankFeeAccountAmount']),
    bankFeeAccountAmountText: financeDecimalText(
      json['bankFeeAccountAmountExact'] ?? json['bankFeeAccountAmount'],
    ),
    otherFeeAccountAmount: _financeDecimalDouble(json['otherFeeAccountAmount']),
    otherFeeAccountAmountText: financeDecimalText(
      json['otherFeeAccountAmountExact'] ?? json['otherFeeAccountAmount'],
    ),
    feeSettlementMode: json['feeSettlementMode'] as String?,
    feeBearer: json['feeBearer'] as String?,
    feePaymentAccountId: json['feePaymentAccountId'] as String?,
    feeAccountCurrencyId: json['feeAccountCurrencyId'] as String?,
    feeAccountExchangeRate: _financeDecimalDouble(
      json['feeAccountExchangeRate'],
    ),
    feeAccountExchangeRateText: financeDecimalText(
      json['feeAccountExchangeRateExact'] ?? json['feeAccountExchangeRate'],
    ),
    settlementGrossLocal: _financeDecimalDouble(
      json['settlementGrossLocal'] ?? json['amountLocal'],
    ),
    settlementGrossLocalText: financeDecimalText(
      json['settlementGrossLocalExact'] ??
          json['settlementGrossLocal'] ??
          json['amountLocalExact'] ??
          json['amountLocal'],
    ),
    otherFeeStyleId: json['otherFeeStyleId'] as String?,
    receiptMethodId: json['receiptMethodId'] as String?,
    paymentMethodId: json['paymentMethodId'] as String?,
    invoiceNo: json['invoiceNo'] as String?,
    operatorId: json['operatorId'] as String?,
    makerId: json['makerId'] as String?,
    makerName: json['makerName'] as String?,
    createdAt: json['createdAt'] as String?,
    approverId: json['approverId'] as String?,
    remark: json['remark'] as String?,
    status: (json['status'] as num?)?.toInt(),
    closed: (json['closed'] as bool?) ?? false,
    glStatus: (json['glStatus'] as num?)?.toInt(),
    items:
        (json['items'] as List?)
            ?.map((e) => FinanceDocItem.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
  );
}

// ===== 应收应付台账（只读）=====

class ArApLedgerItem {
  const ArApLedgerItem({
    required this.id,
    this.direction,
    this.sourceDocType,
    this.sourceDocId,
    this.sourceDocNo,
    this.openItemKind,
    this.billNo,
    this.billDate,
    this.clientId,
    this.supplierId,
    this.clientName,
    this.supplierName,
    this.currencyId,
    this.currencyCode,
    this.currencyName,
    this.exchangeRate,
    this.exchangeRateText,
    this.amountOriginal,
    this.amountOriginalText,
    this.amountOriginalLocal,
    this.amountOriginalLocalText,
    this.amountReceivedOriginal,
    this.amountReceivedOriginalText,
    this.amountReceivedLocal,
    this.amountReceivedLocalText,
    this.amountWriteOffOriginal,
    this.amountWriteOffOriginalText,
    this.amountWriteOffLocal,
    this.amountWriteOffLocalText,
    this.amountBalanceOriginal,
    this.amountBalanceOriginalText,
    this.amountOffsetOriginal,
    this.amountOffsetLocal,
    this.prepaymentAppliedOriginal,
    this.prepaymentAppliedLocal,
    this.amountSettled,
    this.amountSettledText,
    this.amountBalance,
    this.amountBalanceText,
    this.dueDate,
    this.settlementStyleLegacy,
    this.salesOrderIds = const [],
    this.authoritativeSalesOrderId,
    this.salesOrderNos = const [],
    this.settled = false,
    this.settledDate,
    this.status,
    this.remark,
  });

  final String id;
  final String? direction; // AR / AP
  final String? sourceDocType;
  final String? sourceDocId;
  final String? sourceDocNo;
  final String? openItemKind;
  final String? billNo;
  final String? billDate;
  final String? clientId;
  final String? supplierId;
  final String? clientName;
  final String? supplierName;
  final String? currencyId;
  final String? currencyCode;
  final String? currencyName;
  final double? exchangeRate;
  final String? exchangeRateText;
  final double? amountOriginal;
  final String? amountOriginalText;
  final double? amountOriginalLocal;
  final String? amountOriginalLocalText;
  final double? amountReceivedOriginal;
  final String? amountReceivedOriginalText;
  final double? amountReceivedLocal;
  final String? amountReceivedLocalText;
  final double? amountWriteOffOriginal;
  final String? amountWriteOffOriginalText;
  final double? amountWriteOffLocal;
  final String? amountWriteOffLocalText;
  final double? amountBalanceOriginal;
  final String? amountBalanceOriginalText;

  /// 服务端原始十进制文本；保留实际金额及派生账面金额的全部有效位，不经 double 汇总。
  final String? amountOffsetOriginal;
  final String? amountOffsetLocal;
  final String? prepaymentAppliedOriginal;
  final String? prepaymentAppliedLocal;
  final double? amountSettled;
  final String? amountSettledText;
  final double? amountBalance;
  final String? amountBalanceText;
  final String? dueDate;
  final int? settlementStyleLegacy;
  final List<String> salesOrderIds;
  final String? authoritativeSalesOrderId;
  final List<String> salesOrderNos;
  final bool settled;
  final String? settledDate;
  final int? status;
  final String? remark;

  /// 智能取往来方 id（AR→client / AP→supplier）。
  String? get partyId => direction == 'AR' ? clientId : supplierId;

  factory ArApLedgerItem.fromJson(Map<String, dynamic> json) => ArApLedgerItem(
    id: json['id'] as String,
    direction: json['direction'] as String?,
    sourceDocType: json['sourceDocType'] as String?,
    sourceDocId: json['sourceDocId'] as String?,
    sourceDocNo: json['sourceDocNo'] as String?,
    openItemKind: json['openItemKind'] as String?,
    billNo: json['billNo'] as String?,
    billDate: json['billDate'] as String?,
    clientId: json['clientId'] as String?,
    supplierId: json['supplierId'] as String?,
    clientName: json['clientName'] as String?,
    supplierName: json['supplierName'] as String?,
    currencyId: json['currencyId'] as String?,
    currencyCode: json['currencyCode'] as String?,
    currencyName: json['currencyName'] as String?,
    exchangeRate: (json['exchangeRate'] as num?)?.toDouble(),
    exchangeRateText: financeDecimalText(
      json['exchangeRateExact'] ?? json['exchangeRate'],
    ),
    amountOriginal: (json['amountOriginal'] as num?)?.toDouble(),
    amountOriginalText: financeDecimalText(
      json['amountOriginalExact'] ?? json['amountOriginal'],
    ),
    amountOriginalLocal: (json['amountOriginalLocal'] as num?)?.toDouble(),
    amountOriginalLocalText: financeDecimalText(
      json['amountOriginalLocalExact'] ?? json['amountOriginalLocal'],
    ),
    amountReceivedOriginal: (json['amountReceivedOriginal'] as num?)
        ?.toDouble(),
    amountReceivedOriginalText: financeDecimalText(
      json['amountReceivedOriginalExact'] ?? json['amountReceivedOriginal'],
    ),
    amountReceivedLocal: (json['amountReceivedLocal'] as num?)?.toDouble(),
    amountReceivedLocalText: financeDecimalText(
      json['amountReceivedLocalExact'] ?? json['amountReceivedLocal'],
    ),
    amountWriteOffOriginal: (json['amountWriteOffOriginal'] as num?)
        ?.toDouble(),
    amountWriteOffOriginalText: financeDecimalText(
      json['amountWriteOffOriginalExact'] ?? json['amountWriteOffOriginal'],
    ),
    amountWriteOffLocal: (json['amountWriteOffLocal'] as num?)?.toDouble(),
    amountWriteOffLocalText: financeDecimalText(
      json['amountWriteOffLocalExact'] ?? json['amountWriteOffLocal'],
    ),
    amountBalanceOriginal: (json['amountBalanceOriginal'] as num?)?.toDouble(),
    amountBalanceOriginalText: financeDecimalText(
      json['amountBalanceOriginalExact'] ?? json['amountBalanceOriginal'],
    ),
    amountOffsetOriginal: financeDecimalText(
      json['amountOffsetOriginalExact'] ?? json['amountOffsetOriginal'],
    ),
    amountOffsetLocal: financeDecimalText(
      json['amountOffsetLocalExact'] ?? json['amountOffsetLocal'],
    ),
    prepaymentAppliedOriginal: financeDecimalText(
      json['prepaymentAppliedOriginalExact'] ??
          json['prepaymentAppliedOriginal'] ??
          json['amountOffsetOriginalExact'] ??
          json['amountOffsetOriginal'],
    ),
    prepaymentAppliedLocal: financeDecimalText(
      json['prepaymentAppliedLocalExact'] ??
          json['prepaymentAppliedLocal'] ??
          json['amountOffsetLocalExact'] ??
          json['amountOffsetLocal'],
    ),
    amountSettled: (json['amountSettled'] as num?)?.toDouble(),
    amountSettledText: financeDecimalText(
      json['amountSettledExact'] ?? json['amountSettled'],
    ),
    amountBalance: (json['amountBalance'] as num?)?.toDouble(),
    amountBalanceText: financeDecimalText(
      json['amountBalanceExact'] ?? json['amountBalance'],
    ),
    dueDate: json['dueDate'] as String?,
    settlementStyleLegacy: (json['settlementStyleLegacy'] as num?)?.toInt(),
    salesOrderIds:
        (json['salesOrderIds'] as List?)?.whereType<String>().toList() ??
        const [],
    authoritativeSalesOrderId: json['authoritativeSalesOrderId'] as String?,
    salesOrderNos:
        (json['salesOrderNos'] as List?)?.whereType<String>().toList() ??
        const [],
    settled: (json['settled'] as bool?) ?? false,
    settledDate: json['settledDate'] as String?,
    status: (json['status'] as num?)?.toInt(),
    remark: json['remark'] as String?,
  );
}

// ===== 账户流水（只读）=====

class ReconciliationItem {
  const ReconciliationItem({
    required this.id,
    this.billNo,
    this.sourceDocType,
    this.sourceDocId,
    this.accountId,
    this.checkNo,
    this.counterpartName,
    this.inAmount,
    this.outAmount,
    this.billDate,
    this.settledDate,
    this.sourceRemark,
    this.entryKind,
    this.reversalOfId,
  });

  final String id;
  final String? billNo;
  final String? sourceDocType;
  final String? sourceDocId;
  final String? accountId;
  final String? checkNo;
  final String? counterpartName;
  final double? inAmount;
  final double? outAmount;
  final String? billDate;
  final String? settledDate;
  final String? sourceRemark;
  final String? entryKind;
  final String? reversalOfId;

  factory ReconciliationItem.fromJson(Map<String, dynamic> json) =>
      ReconciliationItem(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        sourceDocType: json['sourceDocType'] as String?,
        sourceDocId: json['sourceDocId'] as String?,
        accountId: json['accountId'] as String?,
        checkNo: json['checkNo'] as String?,
        counterpartName: json['counterpartName'] as String?,
        inAmount: (json['inAmount'] as num?)?.toDouble(),
        outAmount: (json['outAmount'] as num?)?.toDouble(),
        billDate: json['billDate'] as String?,
        settledDate: json['settledDate'] as String?,
        sourceRemark: json['sourceRemark'] as String?,
        entryKind: json['entryKind'] as String?,
        reversalOfId: json['reversalOfId'] as String?,
      );
}

// ===== 报表行（4 大类，按需用）=====

/// 单客户/供应商对账行（I/J/K/L 报表）。
class PartyStatementRow {
  const PartyStatementRow({
    this.billDate,
    this.billNo,
    this.entryType,
    this.sourceDocType,
    this.remark,
    this.inAmount,
    this.outAmount,
    this.runningBalance,
  });

  final String? billDate;
  final String? billNo;
  final String? entryType; // POSTED 立帐 / SETTLED 收/付款核销
  final String? sourceDocType;
  final String? remark;
  final double? inAmount;
  final double? outAmount;
  final double? runningBalance;

  factory PartyStatementRow.fromJson(Map<String, dynamic> json) =>
      PartyStatementRow(
        billDate: json['billDate'] as String?,
        billNo: json['billNo'] as String?,
        entryType: json['entryType'] as String?,
        sourceDocType: json['sourceDocType'] as String?,
        remark: json['remark'] as String?,
        inAmount: (json['inAmount'] as num?)?.toDouble(),
        outAmount: (json['outAmount'] as num?)?.toDouble(),
        runningBalance: (json['runningBalance'] as num?)?.toDouble(),
      );
}
