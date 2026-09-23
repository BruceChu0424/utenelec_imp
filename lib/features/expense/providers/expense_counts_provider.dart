import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/badges/badge_registry.dart';

/// 报销五档计数(本人草稿 / 驳回待修订 / 处理中 + 待我审批 / 待我付款)。
///
/// 随工作台徽章汇总一次带回(ADR-108, 原端点 /expense-claims/counts 的同一口径), 不单独请求;
/// 无报销权限时各档为 0。阅读通知不会清掉这些待办。
class ExpenseCounts {
  const ExpenseCounts({
    this.draftCount = 0,
    this.rejectedCount = 0,
    this.pendingApprovalCount = 0,
    this.pendingPaymentCount = 0,
    this.processingCount = 0,
  });
  final int draftCount;
  final int rejectedCount;
  final int pendingApprovalCount;
  final int pendingPaymentCount;

  /// 本人已提交、正在审批链上跑的单(球在审批人/出纳手上，本人此刻不用动手)。
  final int processingCount;

  @override
  bool operator ==(Object other) =>
      other is ExpenseCounts &&
      other.draftCount == draftCount &&
      other.rejectedCount == rejectedCount &&
      other.pendingApprovalCount == pendingApprovalCount &&
      other.pendingPaymentCount == pendingPaymentCount &&
      other.processingCount == processingCount;

  @override
  int get hashCode => Object.hash(
    draftCount,
    rejectedCount,
    pendingApprovalCount,
    pendingPaymentCount,
    processingCount,
  );
}

/// 报销计数(取自徽章汇总)。红黄入口数由服务端目录算好(expenseMine / expenseFinance),
/// 本 provider 只给报销页分段用。
final expenseCountsProvider = Provider<ExpenseCounts>((ref) {
  int fact(String key) => ref.watch(badgeFactProvider(key));
  return ExpenseCounts(
    draftCount: fact(BadgeFact.expenseDraft),
    rejectedCount: fact(BadgeFact.expenseRejected),
    pendingApprovalCount: fact(BadgeFact.expensePendingApproval),
    pendingPaymentCount: fact(BadgeFact.expensePendingPayment),
    processingCount: fact(BadgeFact.expenseProcessing),
  );
});
