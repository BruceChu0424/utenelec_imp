// 「草稿(N)」入口按钮（新建单据页 AppBar 用）。
//
// 背景：销售/采购/委外/钱流/仓库/生产的管理卡都是 skipListOnCreate——点卡片直达
// 新建页，跳过列表。原来的「查看历史」动作下线后，用户从 hub 进入就再也打不开该
// 单据的列表，自己存的草稿也没有入口。本按钮补上这条路：显示本人待处理草稿数，
// 点击进入该单据列表并预选「草稿」段（listLocation?status=draft）。
//
// 口径：数字来自 [draftCountsProvider]（按 *:view 权限 + 对象级归属范围收敛，
// 销售订货单排除财务驳回单）；n=0 时只显示「草稿」不带徽章；无该单据的查看权限
// 时整个按钮隐藏（跳过去也是空列表）。
//
// 【2026-09-11】数字由中性括号 `草稿(3)` 改为**红底白字徽章**贴在文案右侧
// （与管理页/任务中心同款 [UtenNotificationBadge]），并按模块累加到 hub 卡与
// 工作台模块卡——用户口径：草稿是必须处理完的活，看不见就会忘。
//
// 导航走 goFrom：主 Tab 下 push 会静默失效（见 MEMORY「go_router 主Tab前缀push失效」），
// 且带上 returnTo 让列表页返回能回到新建页。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router/nav_helpers.dart';
import '../../shared/auth/permissions.dart';
import '../../shared/providers/draft_counts_provider.dart';
import '../feedback/uten_notification_badge.dart';
import 'uten_app_bar_action_button.dart';

class UtenDraftsButton extends ConsumerWidget {
  const UtenDraftsButton({
    super.key,
    required this.kind,
    required this.listLocation,
    this.label = '草稿',
    this.countScopeNote,
  });

  /// 单据类型（决定计数字段与查看权限点）。
  final DraftDocKind kind;

  /// 该单据的列表路径（不带 query），如 `/sales/orders`。
  final String listLocation;

  /// 按钮文案（默认「草稿」；有计数时渲染为「草稿(N)」）。
  final String label;

  /// 计数口径备注，追加到 tooltip。
  ///
  /// 仓库单据 8 种类型共用一张 `stock_documents`，草稿计数是整模块合计，而落点列表
  /// 只列当前类型——这类「按钮数字 ⊋ 落点列表」的场合必须在 tooltip 里说清楚，
  /// 否则用户会以为列表漏了单。
  final String? countScopeNote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    // 无列表查看权限：隐藏（进去也看不到任何单据）。
    if (!superAdmin && !permissions.contains(kind.viewPerm)) {
      return const SizedBox.shrink();
    }
    // 加载中/失败按 0：按钮照常可点，只是暂不显示计数。
    final count = ref.watch(draftCountsProvider).valueOrNull?.of(kind) ?? 0;
    final note = countScopeNote;
    // 顶栏动作统一形态（深绿实心白字、固定 36 高），与「权限设置」同款；
    // 计数走红色徽章贴在文案右侧（0 不渲染，见 UtenNotificationBadge）。
    return UtenAppBarActionButton(
      key: const Key('uten-drafts-button'),
      icon: Icons.drafts_outlined,
      label: label,
      badge: UtenNotificationBadge(count: count),
      tooltip: note == null
          ? '本人待处理草稿 $count 张，点击查看'
          : '本人待处理草稿 $count 张（$note），点击查看',
      onPressed: () =>
          goFrom(context, '$listLocation?status=$kDraftStatusQuery'),
    );
  }
}
