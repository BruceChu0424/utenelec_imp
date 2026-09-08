import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../components/feedback/uten_notification_badge.dart';
import '../../core/network/api_client.dart';
import '../auth/permissions.dart';
import 'session_provider.dart';

final salesShipmentFinanceCountProvider = FutureProvider.autoDispose<int>((
  ref,
) async {
  ref.watch(sessionProvider);
  final permissions = ref.watch(currentPermissionsProvider);
  if (!ref.watch(isSuperAdminProvider) &&
      !permissions.contains(Perm.financeShipmentAudit)) {
    return 0;
  }
  final timer = Timer(const Duration(seconds: 60), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  final json = await ref
      .watch(apiClientProvider)
      .get('/sales/shipments/pending-finance-count');
  return (json['count'] as num?)?.toInt() ?? 0;
});

class SalesShipmentFinanceBadge extends ConsumerWidget {
  const SalesShipmentFinanceBadge({super.key, this.size = 16});
  final double size;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(salesShipmentFinanceCountProvider).valueOrNull ?? 0;
    return Semantics(
      label: '待财务确认发货 $count 张',
      child: UtenNotificationBadge(count: count, size: size),
    );
  }
}
