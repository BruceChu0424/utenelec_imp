// 钱流单据统一模型（5 单据超集，对应后端各 *ListItem/*Detail/*ItemDto）。
//
// 5 单据差异由 doc_type 决定可选字段是否非空：
// - receipt（销售收款）：clientId + items=AR 核销行（appliedLedgerId）
// - payment（采购付款）：supplierId + items=AP 核销行（appliedLedgerId）
// - expense（一般费用）：accountId + items=分摊行（expenseStyleId + departmentId）
// - otherIncome（其它收入）：accountId + items=分摊行（incomeStyleId + departmentId）
// - bankTransfer（银行存取款）：outAccountId + items=转入行（inAccountId + occurDate）
// 一个超集模型 ×5 配置，避免 5 套重复。UUID=String；金额=(json as num?)；日期=ISO 字符串。
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

  static FinanceDocType byPath(String seg) => FinanceDocType.values.firstWhere(
    (e) => e.pathSegment == seg,
    orElse: () => FinanceDocType.receipt,
  );
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
    this.partyId,
    this.accountId,
    this.outAccountId,
    this.amountLocal,
    this.status,
    this.legacyId,
  });

  final String id;
  final String? billNo;
  final String? billDate;
  final String? partyId; // receipt→clientId / payment→supplierId；其它=null
  final String? accountId;
  final String? outAccountId; // bankTransfer 用
  final double? amountLocal;
  final int? status;
  final int? legacyId;

  factory FinanceDocListItem.fromJson(Map<String, dynamic> json) =>
      FinanceDocListItem(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        // receipt 用 clientId、payment 用 supplierId、其余无 party。
        partyId: (json['clientId'] ?? json['supplierId']) as String?,
        accountId: (json['accountId'] ?? json['outAccountId']) as String?,
        outAccountId: json['outAccountId'] as String?,
        amountLocal: (json['amountLocal'] as num?)?.toDouble(),
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
    this.expenseStyleId,
    this.incomeStyleId,
    this.departmentId,
    this.counterpartAccountId,
    this.counterpartName,
    this.inAccountId,
    this.occurDate,
    this.qty,
    this.price,
    this.amountOriginal,
    this.amountLocal,
    this.exchangeDiff,
    this.summary,
    this.remark,
  });

  final String? id;
  final int? lineNo;
  // receipt/payment 核销
  final String? appliedLedgerId;
  final String? appliedBillNo;
  final String? partyId;
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
  final double? price;
  final double? amountOriginal;
  final double? amountLocal;
  final double? exchangeDiff;
  final String? summary;
  final String? remark;

  factory FinanceDocItem.fromJson(Map<String, dynamic> json) => FinanceDocItem(
    id: json['id'] as String?,
    lineNo: (json['lineNo'] as num?)?.toInt(),
    appliedLedgerId: json['appliedLedgerId'] as String?,
    appliedBillNo: json['appliedBillNo'] as String?,
    partyId: (json['clientId'] ?? json['partyId']) as String?,
    expenseStyleId: json['expenseStyleId'] as String?,
    incomeStyleId: json['incomeStyleId'] as String?,
    departmentId: json['departmentId'] as String?,
    counterpartAccountId: json['counterpartAccountId'] as String?,
    counterpartName: json['counterpartName'] as String?,
    inAccountId: json['inAccountId'] as String?,
    occurDate: json['occurDate'] as String?,
    qty: (json['qty'] as num?)?.toDouble(),
    price: (json['price'] as num?)?.toDouble(),
    amountOriginal: (json['amountOriginal'] as num?)?.toDouble(),
    amountLocal: (json['amountLocal'] as num?)?.toDouble(),
    exchangeDiff: (json['exchangeDiff'] as num?)?.toDouble(),
    summary: json['summary'] as String?,
    remark: json['remark'] as String?,
  );
}

// ===== 5 单据详情（超集）=====

class FinanceDocDetail {
  const FinanceDocDetail({
    required this.id,
    this.legacyId,
    this.billNo,
    this.billDate,
    this.clientId,
    this.supplierId,
    this.accountId,
    this.outAccountId,
    this.counterpartAccountId,
    this.currencyId,
    this.exchangeRate,
    this.amountOriginal,
    this.amountLocal,
    this.bankFee,
    this.otherFee,
    this.receiptMethodId,
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
  final int? legacyId;
  final String? billNo;
  final String? billDate;
  final String? clientId;
  final String? supplierId;
  final String? accountId;
  final String? outAccountId;
  final String? counterpartAccountId;
  final String? currencyId;
  final double? exchangeRate;
  final double? amountOriginal;
  final double? amountLocal;
  final double? bankFee;
  final double? otherFee;
  final String? receiptMethodId;
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

  factory FinanceDocDetail.fromJson(Map<String, dynamic> json) =>
      FinanceDocDetail(
        id: json['id'] as String,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        clientId: json['clientId'] as String?,
        supplierId: json['supplierId'] as String?,
        accountId: json['accountId'] as String?,
        outAccountId: json['outAccountId'] as String?,
        counterpartAccountId: json['counterpartAccountId'] as String?,
        currencyId: json['currencyId'] as String?,
        exchangeRate: (json['exchangeRate'] as num?)?.toDouble(),
        amountOriginal: (json['amountOriginal'] as num?)?.toDouble(),
        amountLocal: (json['amountLocal'] as num?)?.toDouble(),
        bankFee: (json['bankFee'] as num?)?.toDouble(),
        otherFee: (json['otherFee'] as num?)?.toDouble(),
        receiptMethodId: json['receiptMethodId'] as String?,
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
    this.billNo,
    this.billDate,
    this.clientId,
    this.supplierId,
    this.currencyId,
    this.amountOriginalLocal,
    this.amountSettled,
    this.amountBalance,
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
  final String? billNo;
  final String? billDate;
  final String? clientId;
  final String? supplierId;
  final String? currencyId;
  final double? amountOriginalLocal;
  final double? amountSettled;
  final double? amountBalance;
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
    billNo: json['billNo'] as String?,
    billDate: json['billDate'] as String?,
    clientId: json['clientId'] as String?,
    supplierId: json['supplierId'] as String?,
    currencyId: json['currencyId'] as String?,
    amountOriginalLocal: (json['amountOriginalLocal'] as num?)?.toDouble(),
    amountSettled: (json['amountSettled'] as num?)?.toDouble(),
    amountBalance: (json['amountBalance'] as num?)?.toDouble(),
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
      );
}

// ===== 报表行（4 大类，按需用）=====

/// 应收应付汇总行（Z/B/D 报表）。
class ArApSummaryRow {
  const ArApSummaryRow({
    this.ym,
    this.direction,
    this.sourceDocType,
    this.partyId,
    this.partyName,
    this.currencyId,
    this.entryCnt,
    this.originalLocalSum,
    this.settledSum,
    this.balanceSum,
  });

  final String? ym;
  final String? direction;
  final String? sourceDocType;
  final String? partyId;
  final String? partyName;
  final String? currencyId;
  final int? entryCnt;
  final double? originalLocalSum;
  final double? settledSum;
  final double? balanceSum;

  factory ArApSummaryRow.fromJson(Map<String, dynamic> json) => ArApSummaryRow(
    ym: json['ym'] as String?,
    direction: json['direction'] as String?,
    sourceDocType: json['sourceDocType'] as String?,
    partyId: json['partyId'] as String?,
    partyName: json['partyName'] as String?,
    currencyId: json['currencyId'] as String?,
    entryCnt: (json['entryCnt'] as num?)?.toInt(),
    originalLocalSum: (json['originalLocalSum'] as num?)?.toDouble(),
    settledSum: (json['settledSum'] as num?)?.toDouble(),
    balanceSum: (json['balanceSum'] as num?)?.toDouble(),
  );
}

/// 单据明细/汇总行（E/F/G/H/M/N/O/P 报表）。
class FinanceDocReportRow {
  const FinanceDocReportRow({
    this.id,
    this.billNo,
    this.billDate,
    this.partyId,
    this.partyName,
    this.accountId,
    this.accountName,
    this.amountOriginal,
    this.amountLocal,
    this.status,
    this.remark,
    this.ym,
    this.departmentId,
    this.departmentName,
    this.styleId,
    this.styleName,
    this.cnt,
    this.amountOriginalSum,
    this.amountLocalSum,
  });

  final String? id;
  final String? billNo;
  final String? billDate;
  final String? partyId;
  final String? partyName;
  final String? accountId;
  final String? accountName;
  final double? amountOriginal;
  final double? amountLocal;
  final int? status;
  final String? remark;

  // 汇总行（F/H/N/P）才有：
  final String? ym;
  final String? departmentId;
  final String? departmentName;
  final String? styleId;
  final String? styleName;
  final int? cnt;
  final double? amountOriginalSum;
  final double? amountLocalSum;

  factory FinanceDocReportRow.fromJson(Map<String, dynamic> json) =>
      FinanceDocReportRow(
        id: json['id'] as String?,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        partyId: json['partyId'] as String?,
        partyName: json['partyName'] as String?,
        accountId: json['accountId'] as String?,
        accountName: json['accountName'] as String?,
        amountOriginal: (json['amountOriginal'] as num?)?.toDouble(),
        amountLocal: (json['amountLocal'] as num?)?.toDouble(),
        status: (json['status'] as num?)?.toInt(),
        remark: json['remark'] as String?,
        ym: json['ym'] as String?,
        departmentId: json['departmentId'] as String?,
        departmentName: json['departmentName'] as String?,
        styleId: json['styleId'] as String?,
        styleName: json['styleName'] as String?,
        cnt: (json['cnt'] as num?)?.toInt(),
        amountOriginalSum: (json['amountOriginalSum'] as num?)?.toDouble(),
        amountLocalSum: (json['amountLocalSum'] as num?)?.toDouble(),
      );
}

/// 账户流水对账行（S 报表，滚动余额）。
class AccountStatementRow {
  const AccountStatementRow({
    this.id,
    this.billDate,
    this.billNo,
    this.sourceDocType,
    this.counterpartName,
    this.checkNo,
    this.inAmount,
    this.outAmount,
    this.runningBalance,
  });

  final String? id;
  final String? billDate;
  final String? billNo;
  final String? sourceDocType;
  final String? counterpartName;
  final String? checkNo;
  final double? inAmount;
  final double? outAmount;
  final double? runningBalance;

  factory AccountStatementRow.fromJson(Map<String, dynamic> json) =>
      AccountStatementRow(
        id: json['id'] as String?,
        billDate: json['billDate'] as String?,
        billNo: json['billNo'] as String?,
        sourceDocType: json['sourceDocType'] as String?,
        counterpartName: json['counterpartName'] as String?,
        checkNo: json['checkNo'] as String?,
        inAmount: (json['inAmount'] as num?)?.toDouble(),
        outAmount: (json['outAmount'] as num?)?.toDouble(),
        runningBalance: (json['runningBalance'] as num?)?.toDouble(),
      );
}

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
