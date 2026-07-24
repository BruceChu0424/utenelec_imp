// 访客审批待办红色徽章（工作台模块角标使用）。
// VisitorPendingBadge：HR 待审批数；VisitorHostPendingBadge：被访人待确认数。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../providers/visitor_pending_count_provider.dart';

class VisitorPendingBadge extends ConsumerWidget {
  const VisitorPendingBadge({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(visitorPendingCountProvider);
    return UtenNotificationBadge(count: count, size: size);
  }
}

class VisitorHostPendingBadge extends ConsumerWidget {
  const VisitorHostPendingBadge({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(visitorHostPendingCountProvider);
    return UtenNotificationBadge(count: count, size: size);
  }
}
