// HR 工作台主页（行政与人力资源部）：我处理中的事项 + 事务入口。
// 数据来自服务端按「今天」动态计算（hrTaskSummaryProvider），任务软认领见 ADR-021。
// 子页面：/hr/tasks/:type(转正办理/生日关怀/入职周年/新近入职/证件核对)。
// 2026-10-06 版式改版：
//  - 事务入口从整行 ListTile 改为自适应小卡网格(UtenResponsiveGrid：
//    手机 2 列 / 中宽 3 列 / 桌面 5 列)；今日概览 4 张统计卡与证件待核对
//    红横幅退役(与事务办理卡重复，数字并入卡片徽章)；
//  - 卡片待办数用 UtenNotificationBadge 红色通知徽章(有需处理时)，
//    无待办显示中性灰 0(2026-10-06 用户口径：数字常显)；
//  - 「快捷发布祝福」三张大瓦片改为内容宽度的紧凑横排胶囊(图标+文字，Wrap 自适应换行)；
//  - 右下角悬浮操作组：有入职权限者给「入职登记」主按钮(与员工列表页 FAB 同动作)；
//  - 正文统一包 UtenContentContainer(与各 hub 页同款 gutter)，区块内边距收口为 s4。
// 文档：docs/03-页面/HR任务中心.md
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_notification_badge.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_drafts_page.dart';
import '../models/hr_task_summary.dart';
import '../providers/hr_task_summary_provider.dart';
import '../widgets/hr_task_widgets.dart';

class HrWorkbenchPage extends ConsumerWidget {
  const HrWorkbenchPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(hrTaskSummaryProvider);
    final l10n = AppLocalizations.of(context);
    final isSuperAdmin = ref.watch(isSuperAdminProvider);
    final perms = ref.watch(currentPermissionsProvider);
    final canPublish = isSuperAdmin || perms.contains(Perm.noticePublish);
    // 证件核对入口与子页路由守卫同一份判定(超管或 employee:pii:edit；
    // 服务端同口径过滤列表与计数)。
    final canFixIdentity = locationAllowedFor(
      perms,
      isSuperAdmin,
      RouteName.hrTaskList(HrTaskType.identity.taskType),
    );
    // 右下悬浮「入职登记」与员工列表页/工作台入口同一份守卫(any-of employee:create
    // 再加 all-of 档案三码，permission_by_path 两段都拦)。
    final canOnboard = locationAllowedFor(
      perms,
      isSuperAdmin,
      '/employee/onboarding',
    );

    Widget body = async.when(
      loading: () => const UtenSkeletonList(itemCount: 6),
      error: (_, _) => UtenEmpty.error(
        message: '加载工作台失败，请稍后重试',
        actionLabel: '重试',
        onAction: () => ref.read(hrTaskSummaryProvider.notifier).refresh(),
      ),
      data: (s) => RefreshIndicator(
        onRefresh: () => ref.read(hrTaskSummaryProvider.notifier).refresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          // compact 悬浮胶囊 + 右下悬浮按钮避让：滚到底末卡要能越过胶囊与按钮
          padding: EdgeInsets.only(
            bottom: canOnboard
                ? math.max(
                    UtenSpacing.s32,
                    UtenCapsuleNavScope.occlusionOf(context) + 76,
                  )
                : math.max(32, UtenCapsuleNavScope.occlusionOf(context)),
          ),
          children: [
            _myClaims(context, s),
            _entries(context, s, canFixIdentity: canFixIdentity),
            if (canPublish) _quickNotice(context, l10n),
            if (s.unconfirmedLegacyCount > 0) _legacyBanner(context, s),
          ],
        ),
      ),
    );
    body = UtenContentContainer(child: body);

    return Scaffold(
      appBar: UtenAppBar(
        title: 'HR 工作台',
        showBackButton: true,
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => ref.read(hrTaskSummaryProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          // 草稿入口走右上角按钮（2026-09-27），不再在左上角占一行分段栏。
          const FormDraftsAppBarButton(categoryId: 'hr'),
        ],
      ),
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: canOnboard
          ? UtenFloatingActionGroup(
              children: [
                UtenButton(
                  key: const ValueKey('hr-workbench-fab-onboard'),
                  size: UtenButtonSize.large,
                  icon: Icons.person_add_rounded,
                  onPressed: () => context.push('/employee/onboarding'),
                  child: Text(l10n.employeeFabOnboard),
                ),
              ],
            )
          : null,
      body: body,
    );
  }

  // ---- 快捷发布祝福：内容宽度的紧凑胶囊横排(图标+文字)，Wrap 自适应换行 ----
  // 生日/周年的按人祝福在对应子页(一键批量 + 逐行送祝福)，主页只留通用与
  // 新婚/新生儿三类模板直达；「发通知」是发布页裸入口(不预选类型)。
  Widget _quickNotice(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    String publishWith(String type) => '${RouteName.noticePublish}?type=$type';
    final tiles = <(IconData, Color, String, VoidCallback)>[
      (
        Icons.campaign_rounded,
        UtenColors.teal600,
        l10n.noticeQuickPublish,
        () => context.push(RouteName.noticePublish),
      ),
      (
        Icons.favorite_rounded,
        UtenColors.catFuchsia,
        l10n.noticeQuickWedding,
        () => context.push(publishWith('wedding')),
      ),
      (
        Icons.child_care_rounded,
        UtenColors.catSky,
        l10n.noticeQuickNewborn,
        () => context.push(publishWith('newborn')),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s4,
        UtenSpacing.s20,
        UtenSpacing.s4,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: UtenSpacing.s4,
              bottom: UtenSpacing.s8,
            ),
            child: Text(
              l10n.noticeQuickCelebrationTitle,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              for (final (icon, color, label, onTap) in tiles)
                _QuickTile(
                  icon: icon,
                  color: color,
                  label: label,
                  onTap: onTap,
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ---- 我处理中的事项（跨区块汇总我认领的；可点进子页继续处理） ----
  Widget _myClaims(BuildContext context, HrTaskSummary s) {
    final mine = <(HrTaskType, HrTaskItem)>[
      for (final t in HrTaskType.values)
        for (final it in hrTaskItemsOf(s, t))
          if (it.claimedByMe) (t, it),
    ];
    if (mine.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    // UtenCard 的 Material 即 ink 表面：内部 HrTaskTile 的点按涟漪照常渲染。
    return UtenCard(
      margin: const EdgeInsets.fromLTRB(
        UtenSpacing.s4,
        UtenSpacing.s12,
        UtenSpacing.s4,
        0,
      ),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s12,
              UtenSpacing.s16,
              UtenSpacing.s4,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.assignment_ind_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  '我处理中的事项',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  '${mine.length} 项',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < mine.length && i < 5; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            HrTaskTile(
              type: mine[i].$1,
              item: mine[i].$2,
              isToday: hrTaskIsToday(s, mine[i].$1, mine[i].$2),
            ),
          ],
          if (mine.length > 5)
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
              child: Center(
                child: Text(
                  '其余 ${mine.length - 5} 项见各事务子页',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---- 事务办理：自适应小卡网格(手机 2 列 / 中宽 3 列 / 桌面 5 列) ----
  // 卡片 = 图标 + 待办数(图标行右端，>0 红色通知徽章 / =0 中性灰常显) + 标题 +
  // 口径说明两行；配色 confirm=teal/birthday=粉/anniversary=琥珀/newhire=祖母绿，
  // 证件核对=error 红(与子页红标一致)。
  Widget _entries(
    BuildContext context,
    HrTaskSummary s, {
    required bool canFixIdentity,
  }) {
    final theme = Theme.of(context);
    final entries = <(HrTaskType, int, String, Color)>[
      (
        HrTaskType.confirm,
        s.confirmOverdue.length +
            s.confirmToday.length +
            s.confirmUpcoming.length,
        '逾期 ${s.confirmOverdue.length} · 今日 ${s.confirmToday.length} · 临近 ${s.confirmUpcoming.length}',
        UtenColors.teal600,
      ),
      (
        HrTaskType.birthday,
        s.birthdayToday.length + s.birthdayUpcoming.length,
        '今日 ${s.birthdayToday.length} · 30 天内 ${s.birthdayUpcoming.length}',
        UtenColors.catPink,
      ),
      (
        HrTaskType.anniversary,
        s.anniversaryToday.length,
        '入职满年纪念，及时送上祝福',
        UtenColors.catAmber,
      ),
      (
        HrTaskType.newhire,
        s.newHires.length,
        '适应期跟进，7 天内高亮',
        UtenColors.catEmerald,
      ),
      if (canFixIdentity)
        (
          HrTaskType.identity,
          s.identityReview.length,
          '缺失、校验未通过或尚未校验',
          theme.colorScheme.error,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s4,
        UtenSpacing.s12,
        UtenSpacing.s4,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: UtenSpacing.s4,
              bottom: UtenSpacing.s8,
            ),
            child: Text(
              '事务办理',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          UtenResponsiveGrid(
            itemCount: entries.length,
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            columns: const UtenResponsiveColumns(
              compact: 2,
              medium: 3,
              expanded: 5,
            ),
            itemBuilder: (context, i, _) {
              final (type, count, detail, accent) = entries[i];
              return _EntryCard(
                key: ValueKey('hr-workbench-entry-${type.taskType}'),
                type: type,
                count: count,
                detail: detail,
                accent: accent,
                onTap: () => context.push(RouteName.hrTaskList(type.taskType)),
              );
            },
          ),
        ],
      ),
    );
  }

  // ---- 老数据补录提示 ----
  Widget _legacyBanner(BuildContext context, HrTaskSummary s) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        UtenSpacing.s4,
        UtenSpacing.s12,
        UtenSpacing.s4,
        0,
      ),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '另有 ${s.unconfirmedLegacyCount} 名入职满一年的员工未登记转正日期，'
              '请在员工档案中使用「登记转正」补登（编辑档案不可直改转正日期）。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 事务办理小卡：图标行(左图标、右待办数) + 标题 + 口径说明；
/// 有待办 = UtenNotificationBadge 红色通知徽章(与全站导航/工作台角标同款)，
/// 无待办 = 中性灰 0 常显(数字恒在，一眼区分有无事项)。
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    super.key,
    required this.type,
    required this.count,
    required this.detail,
    required this.accent,
    required this.onTap,
  });

  final HrTaskType type;
  final int count;

  /// 口径说明（逾期/今日/临近的拆分或补充说明），最多两行。
  final String detail;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: '${type.title}，$count，$detail',
      child: UtenCard(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    borderRadius: UtenRadius.mdAll,
                  ),
                  child: Icon(type.icon, size: 20, color: accent),
                ),
                const Spacer(),
                if (count > 0)
                  // 与工作台模块小卡同款 1.25 倍放大红徽章(hub 卡是 1.4)。
                  UtenBadgeScale(
                    scale: 1.25,
                    child: UtenNotificationBadge(
                      key: ValueKey(
                        'hr-workbench-entry-count-${type.taskType}',
                      ),
                      count: count,
                    ),
                  )
                else
                  Text(
                    '0',
                    key: ValueKey('hr-workbench-entry-count-${type.taskType}'),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(
              type.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 快捷发布祝福紧凑胶囊：彩色小图标 + 文字，高度 48，宽度随内容。
class _QuickTile extends StatelessWidget {
  const _QuickTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s12,
      ),
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: UtenRadius.mdAll,
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
