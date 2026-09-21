import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;

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
  int get mine => draftCount + rejectedCount;
  int get finance => pendingApprovalCount + pendingPaymentCount;

  factory ExpenseCounts.fromJson(Map<String, dynamic> json) => ExpenseCounts(
    draftCount: (json['draftCount'] as num?)?.toInt() ?? 0,
    rejectedCount: (json['rejectedCount'] as num?)?.toInt() ?? 0,
    pendingApprovalCount: (json['pendingApprovalCount'] as num?)?.toInt() ?? 0,
    pendingPaymentCount: (json['pendingPaymentCount'] as num?)?.toInt() ?? 0,
    processingCount: (json['processingCount'] as num?)?.toInt() ?? 0,
  );
}

/// One scoped request drives all expense badges; reading a notice never clears it.
final expenseCountsProvider = FutureProvider<ExpenseCounts>((ref) async {
  ref.watch(masterDataSessionKeyProvider);
  final permissions = ref.watch(currentPermissionsProvider);
  if (![
    Perm.expenseApply,
    Perm.expenseApprove,
    Perm.expensePay,
  ].any(permissions.contains)) {
    return const ExpenseCounts();
  }
  final timer = Timer(const Duration(seconds: 60), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ExpenseCounts.fromJson(
    await ref.watch(apiClientProvider).get('/expense-claims/counts'),
  );
});

final expenseMineTodoCountProvider = Provider<int>((ref) {
  final value = ref.watch(expenseCountsProvider);
  return value.isReloading ? 0 : value.valueOrNull?.mine ?? 0;
});
final expenseFinanceTodoCountProvider = Provider<int>((ref) {
  final value = ref.watch(expenseCountsProvider);
  return value.isReloading ? 0 : value.valueOrNull?.finance ?? 0;
});

/// 我的报销 · 处理中(黄色进行中徽章，ADR-100)：本人已提交、还没结案的单。
///
/// 与红色两枚共用同一次 `/expense-claims/counts`，不额外发请求。取值沿用
/// 邻居的 `isReloading` 判据：那只在身份切换(依赖变更重建)时为真，把上一个
/// 身份的数字挡掉；60s 自刷走的是 invalidateSelf(isRefreshing)，旧值照常带住，
/// 徽章不会每分钟闪一下(准则 §四之三)。
final expenseMineProcessingCountProvider = Provider<int>((ref) {
  final value = ref.watch(expenseCountsProvider);
  return value.isReloading ? 0 : value.valueOrNull?.processingCount ?? 0;
});
