// 钱流单据配置（5 单据差异声明，驱动 list/detail/edit 页）。
//
// 一套页面 ×5 配置，保证 UI 一致。差异：
// - partyMode: receipt→client(核销 AR) / payment→supplier(核销 AP) / 其它→none
// - itemMode: settle(receipt/payment AR/AP 核销) / allocate(expense/otherIncome 部门分摊) /
//   transfer(bankTransfer 转入行)
// - hasCurrency/hasBankFee/hasInvoice 等表头开关
// 权限点用字符串常量（finance_*:view/edit），暂不进 permissions.dart（由用户统一接线）。
import 'package:flutter/material.dart';

import '../models/finance_doc.dart';

/// 5 单据的往来方模式。
enum PartyMode { none, client, supplier }

/// 5 单据的明细模式。
enum ItemMode { settle, allocate, transfer }

class FinanceDocConfig {
  const FinanceDocConfig({
    required this.type,
    required this.label,
    required this.shortLabel,
    required this.icon,
    required this.listPerm,
    required this.editPerm,
    this.partyMode = PartyMode.none,
    this.itemMode = ItemMode.settle,
    this.hasCurrency = true,
    this.hasBankFee = false,
    this.hasOtherFee = false,
    this.hasInvoiceNo = false,
    this.accountLabel = '收款账户',
    this.partyLabel = '往来方',
    this.amountLabel = '金额',
  });

  final FinanceDocType type;
  final String label; // 销售收款单
  final String shortLabel; // 收款
  final IconData icon;
  final String listPerm;
  final String editPerm;

  /// 往来方：收款→客户、付款→供应商、其它→无。
  final PartyMode partyMode;
  bool get hasParty => partyMode != PartyMode.none;
  bool get isClient => partyMode == PartyMode.client;
  bool get isSupplier => partyMode == PartyMode.supplier;

  /// 明细模式：核销 / 分摊 / 转入。
  final ItemMode itemMode;
  bool get isSettle => itemMode == ItemMode.settle;
  bool get isAllocate => itemMode == ItemMode.allocate;
  bool get isTransfer => itemMode == ItemMode.transfer;

  // 表头字段开关
  final bool hasCurrency;
  final bool hasBankFee; // 仅 receipt
  final bool hasOtherFee; // 仅 receipt
  final bool hasInvoiceNo; // receipt/bankTransfer

  // 列/表单文案
  final String accountLabel; // 收款账户/付款账户/费用账户/收入账户/转出账户
  final String partyLabel; // 客户/供应商
  final String amountLabel;

  /// 明细是否需要「从应收应付引入」（仅 receipt/payment 核销）。
  bool get hasArApLink => isSettle;

  static const receipt = FinanceDocConfig(
    type: FinanceDocType.receipt,
    label: '销售收款单',
    shortLabel: '收款',
    icon: Icons.south_west_outlined,
    listPerm: 'finance_receipt:view',
    editPerm: 'finance_receipt:edit',
    partyMode: PartyMode.client,
    itemMode: ItemMode.settle,
    hasBankFee: true,
    hasOtherFee: true,
    hasInvoiceNo: true,
    accountLabel: '收款账户',
    partyLabel: '客户',
  );

  static const payment = FinanceDocConfig(
    type: FinanceDocType.payment,
    label: '采购付款单',
    shortLabel: '付款',
    icon: Icons.north_east_outlined,
    listPerm: 'finance_payment:view',
    editPerm: 'finance_payment:edit',
    partyMode: PartyMode.supplier,
    itemMode: ItemMode.settle,
    accountLabel: '付款账户',
    partyLabel: '供应商',
  );

  static const expense = FinanceDocConfig(
    type: FinanceDocType.expense,
    label: '一般费用单',
    shortLabel: '费用',
    icon: Icons.outbound_outlined,
    listPerm: 'finance_expense:view',
    editPerm: 'finance_expense:edit',
    itemMode: ItemMode.allocate,
    accountLabel: '费用账户',
    amountLabel: '费用金额',
  );

  static const otherIncome = FinanceDocConfig(
    type: FinanceDocType.otherIncome,
    label: '其它收入单',
    shortLabel: '收入',
    icon: Icons.south_west_outlined,
    listPerm: 'finance_other_income:view',
    editPerm: 'finance_other_income:edit',
    itemMode: ItemMode.allocate,
    accountLabel: '收入账户',
    amountLabel: '收入金额',
  );

  static const bankTransfer = FinanceDocConfig(
    type: FinanceDocType.bankTransfer,
    label: '银行存取款单',
    shortLabel: '存取款',
    icon: Icons.swap_horiz_rounded,
    listPerm: 'finance_bank_transfer:view',
    editPerm: 'finance_bank_transfer:edit',
    itemMode: ItemMode.transfer,
    hasInvoiceNo: true,
    accountLabel: '转出账户',
  );

  static FinanceDocConfig by(FinanceDocType t) {
    switch (t) {
      case FinanceDocType.receipt:
        return receipt;
      case FinanceDocType.payment:
        return payment;
      case FinanceDocType.expense:
        return expense;
      case FinanceDocType.otherIncome:
        return otherIncome;
      case FinanceDocType.bankTransfer:
        return bankTransfer;
    }
  }
}
