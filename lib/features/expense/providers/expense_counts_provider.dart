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
  });
  final int draftCount;
  final int rejectedCount;
  final int pendingApprovalCount;
  final int pendingPaymentCount;
  int get mine => draftCount + rejectedCount;
  int get finance => pendingApprovalCount + pendingPaymentCount;

  factory ExpenseCounts.fromJson(Map<String, dynamic> json) => ExpenseCounts(
    draftCount: (json['draftCount'] as num?)?.toInt() ?? 0,
    rejectedCount: (json['rejectedCount'] as num?)?.toInt() ?? 0,
    pendingApprovalCount: (json['pendingApprovalCount'] as num?)?.toInt() ?? 0,
    pendingPaymentCount: (json['pendingPaymentCount'] as num?)?.toInt() ?? 0,
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
