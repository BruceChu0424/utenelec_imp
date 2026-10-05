// HR 工作台主页（行政与人力资源部）：今日概览统计 + 我处理中的事项 + 事务入口。
// 数据来自服务端按「今天」动态计算（hrTaskSummaryProvider），任务软认领见 ADR-021。
// 子页面：/hr/tasks/:type(转正办理/生日关怀/入职周年/新近入职/证件核对)。
// 2026-10-05 证件核对：有待核对员工时概览上方红色横幅「去处理」；入口只给能修改证件的人
// (超管或 employee:pii:edit)。4 张统计卡布局不动。
// 2026-09-18 UI 统一收口：加载态改 UtenSkeletonList，区块卡片统一 UtenCard。
// 文档：docs/03-页面/HR任务中心.md
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
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
    final isCompact = context.breakpoint.isCompact;
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
          // compact 悬浮胶囊避让：滚到底末卡要能越过胶囊
          padding: EdgeInsets.only(
            bottom: math.max(32, UtenCapsuleNavScope.occlusionOf(context)),
          ),
          children: [
            if (s.identityReview.isNotEmpty) _identityBanner(context, s),
            _overview(context, s, isCompact),
            _myClaims(context, s),
            _entries(context, s, isCompact, canFixIdentity: canFixIdentity),
            if (canPublish) _quickNotice(context, isCompact),
            if (s.unconfirmedLegacyCount > 0) _legacyBanner(context, s),
          ],
        ),
      ),
    );
    if (isCompact) body = UtenContentContainer(child: body);

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
      body: body,
    );
  }

  // ---- 今日概览：4 张紧凑统计卡（≈72dp，图标+数字一行 / 标签一行），点击进对应子页 ----
  // count=0 整卡弱化为中性灰、>0 时鲜活——一眼分清有无待办。
  Widget _overview(BuildContext context, HrTaskSummary s, bool isCompact) {
    final cards = [
      (
        HrTaskType.confirm,
        s.confirmToday.length + s.confirmOverdue.length,
        '今日/逾期',
        UtenColors.teal600,
      ),
      (HrTaskType.birthday, s.birthdayToday.length, '今日生日', UtenColors.catPink),
      (
        HrTaskType.anniversary,
        s.anniversaryToday.length,
        '今日周年',
        UtenColors.catAmber,
      ),
      (HrTaskType.newhire, s.newHires.length, '近 30 天', UtenColors.catEmerald),
    ];
    final built = [
      for (final (type, count, caption, accent) in cards)
        _StatCard(
          type: type,
          count: count,
          caption: caption,
          accent: accent,
          onTap: () => context.push(RouteName.hrTaskList(type.taskType)),
        ),
    ];
    // 固定高度卡：用 Expanded 行布局保证高度不随屏宽漂移；窄屏 2 列、中宽 4 列。
    final Widget grid = isCompact
        ? Column(
            children: [
              _statRow(built.sublist(0, 2)),
              const SizedBox(height: UtenSpacing.s8),
              _statRow(built.sublist(2, 4)),
            ],
          )
        : _statRow(built);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenSpacing.s12,
        0,
      ),
      child: grid,
    );
  }

  // ---- 证件待核对横幅(红)：有人就显示，「去处理」进证件核对子页 ----
  Widget _identityBanner(BuildContext context, HrTaskSummary s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenSpacing.s12,
        0,
      ),
      child: UtenInlineNotice(
        key: const ValueKey('hr-identity-review-banner'),
        level: UtenInlineNoticeLevel.error,
        title: '有 ${s.identityReview.length} 名员工的证件号码待核对',
        message: '证件号码缺失、校验未通过或尚未校验，请对照员工证件核对修改。不影响员工开通和使用登录账号。',
        trailing: FilledButton.tonal(
          key: const ValueKey('hr-identity-review-go'),
          onPressed: () =>
              context.push(RouteName.hrTaskList(HrTaskType.identity.taskType)),
          child: const Text('去处理'),
        ),
      ),
    );
  }

  Widget _statRow(List<Widget> cards) {
    final children = <Widget>[];
    for (var i = 0; i < cards.length; i++) {
      if (i > 0) children.add(const SizedBox(width: UtenSpacing.s8));
      children.add(Expanded(child: cards[i]));
    }
    return Row(children: children);
  }

  // ---- 快捷发布祝福：点类型瓦片直达通知发布页并预填对应类型模板 ----
  Widget _quickNotice(BuildContext context, bool isCompact) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    String publishWith(String type) => '${RouteName.noticePublish}?type=$type';
    final tiles = <(IconData, Color, String, VoidCallback)>[
      (
        Icons.campaign_rounded,
        UtenColors.teal500,
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
        UtenSpacing.s12,
        UtenSpacing.s20,
        UtenSpacing.s12,
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.noticeQuickCelebrationTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  l10n.noticeQuickCelebrationSubtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: UtenSpacing.s8,
            crossAxisSpacing: UtenSpacing.s8,
            childAspectRatio: 1.05,
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
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenSpacing.s12,
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

  // ---- 事务入口：四个子页面(能修改证件的人再加「证件核对」) ----
  Widget _entries(
    BuildContext context,
    HrTaskSummary s,
    bool isCompact, {
    required bool canFixIdentity,
  }) {
    final theme = Theme.of(context);
    final entries = [
      (
        HrTaskType.confirm,
        '${s.confirmOverdue.length + s.confirmToday.length + s.confirmUpcoming.length} 人待办理',
        '逾期 ${s.confirmOverdue.length} · 今日 ${s.confirmToday.length} · 临近 ${s.confirmUpcoming.length}',
      ),
      (
        HrTaskType.birthday,
        '${s.birthdayToday.length + s.birthdayUpcoming.length} 人生日临近',
        '今日 ${s.birthdayToday.length} · 30 天内 ${s.birthdayUpcoming.length}',
      ),
      (
        HrTaskType.anniversary,
        '${s.anniversaryToday.length} 人今日周年',
        '入职满年纪念，及时送上祝福',
      ),
      (HrTaskType.newhire, '${s.newHires.length} 人近 30 天入职', '适应期跟进，7 天内高亮'),
      if (canFixIdentity)
        (
          HrTaskType.identity,
          '${s.identityReview.length} 人证件待核对',
          '缺失、校验未通过或尚未校验的证件号码',
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenSpacing.s12,
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
          for (final (type, headline, caption) in entries)
            UtenCard(
              key: ValueKey('hr-workbench-entry-${type.taskType}'),
              margin: const EdgeInsets.only(bottom: UtenSpacing.s12),
              padding: EdgeInsets.zero,
              child: ListTile(
                onTap: () => context.push(RouteName.hrTaskList(type.taskType)),
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: UtenRadius.lgAll,
                  ),
                  child: Icon(
                    type.icon,
                    size: 20,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                title: Text(
                  type.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text('$headline · $caption'),
                trailing: const Icon(Icons.chevron_right_rounded),
              ),
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
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenSpacing.s12,
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

/// 今日概览紧凑统计卡（≈72dp）：图标 + 数字同行，标签下行；count=0 弱化为中性灰。
class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.type,
    required this.count,
    required this.caption,
    required this.accent,
    required this.onTap,
  });

  final HrTaskType type;
  final int count;
  final String caption;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = count > 0;
    final color = active ? accent : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      label: '${type.title}，$count，$caption',
      child: SizedBox(
        height: 72,
        child: UtenCard(
          padding: EdgeInsets.zero,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s12,
              vertical: UtenSpacing.s12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: active ? 0.14 : 0.08),
                        borderRadius: UtenRadius.mdAll,
                      ),
                      child: Icon(type.icon, size: 16, color: color),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Text(
                      '$count',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: color,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
    return UtenCard(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(UtenSpacing.s8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
