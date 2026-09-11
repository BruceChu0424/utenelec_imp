import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../components/feedback/uten_notification_badge.dart';
import '../../core/network/api_client.dart';
import '../auth/permissions.dart';
import 'session_provider.dart';

// 徽章计数 provider 一律**常驻**（不 autoDispose）——2026-09-11 用户反馈：
// 仓库/品质的徽章「进页面要等一会才出现」「冒出来又消失又冒出来」，而采购点进去就有。
// 差别不在后端快慢，在生命周期：采购是常驻 StateNotifier，这些是 autoDispose，
// 离开页面即销毁、回来从零 loading，而 todo_badge_registry 把 loading 记成 0。
// 常驻后 invalidateSelf 刷新期间 AsyncValue 会带住旧值（见 registry 的 valueOrNull），
// 徽章不再闪；没人看时定时器不再续期，也不会空转发请求。
final salesShipmentFinanceCountProvider = FutureProvider<int>((ref) async {
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
