// HR 待审数量红色徽章（导航栏使用）。
// 文档：docs/03-页面/我的页.md（§HR 导航红色数字徽章）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/pending_review_provider.dart';

class HrPendingBadge extends ConsumerWidget {
  const HrPendingBadge({super.key, this.size = 16, this.showLabel = false});

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pendingReviewCountProvider);
    if (count <= 0) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final label = count > 99 ? '99+' : count.toString();

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: showLabel ? 8 : (size / 4),
        vertical: showLabel ? 2 : 0,
      ),
      constraints: BoxConstraints(minWidth: size, minHeight: size),
      decoration: BoxDecoration(
        color: theme.colorScheme.error,
        borderRadius: BorderRadius.circular(size),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: theme.colorScheme.onError,
          fontSize: showLabel ? 11 : 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}