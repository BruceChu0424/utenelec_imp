// 草稿数红色徽章（hub 单据卡 / 新建页「草稿」按钮）。
//
// 数据源 = [draftCountsProvider]（跨模块 60s 轮询，按 *:view 权限 + 对象级归属范围收敛）；
// count<=0 不渲染，无该类型查看权限同样不渲染。
//
// 【口径变更 2026-09-11】本组件原名 `UtenDraftCountSuffix`，渲染中性括号 `(N)`，
// 理由是「草稿是本人待自审的私活，不是别人给我的待办」。当日用户明确推翻：
// 草稿是**必须由我处理完的活**，看不见就会忘，要求改成红底白字徽章，并且
// **逐级累加**到 hub 卡与工作台模块卡（与采购任务中心同款）。
// 于是草稿改走 [UtenNotificationBadge]，并在 `todo_badge_registry` 里按模块登记。
// 见 docs/00-项目准则/14-徽章与计数口径.md §草稿。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/auth/permissions.dart';
import '../../shared/providers/draft_counts_provider.dart';
import 'uten_notification_badge.dart';

class UtenDraftBadge extends ConsumerWidget {
  const UtenDraftBadge({super.key, required this.kind, this.size = 16});

  final DraftDocKind kind;

  /// 徽章直径；hub 单据卡用默认 16，顶栏按钮内用 16，工作台模块卡用 20。
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    if (!superAdmin && !permissions.contains(kind.viewPerm)) {
      return const SizedBox.shrink();
    }
    // 加载中/失败按 0（不放大成异常态，与 module_badge_sum 的降级口径一致）。
    final count = ref.watch(draftCountsProvider).valueOrNull?.of(kind) ?? 0;
    if (count <= 0) return const SizedBox.shrink();
    return Tooltip(
      message: '草稿 $count 张（本人未提交）',
      child: UtenNotificationBadge(count: count, size: size),
    );
  }
}
