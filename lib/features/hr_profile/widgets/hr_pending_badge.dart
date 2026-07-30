// HR 待审数量红色徽章（导航栏使用）。
// 文档：docs/03-页面/我的页.md（§HR 导航红色数字徽章）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/auth/pending_review_provider.dart';

class HrPendingBadge extends ConsumerWidget {
  const HrPendingBadge({super.key, this.size = 16, this.showLabel = false});

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pendingReviewCountProvider);
    return UtenNotificationBadge(
      count: count,
      size: size,
      showLabel: showLabel,
    );
  }
}
