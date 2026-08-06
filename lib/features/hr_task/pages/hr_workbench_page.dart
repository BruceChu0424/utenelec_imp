// HR 工作台主页（行政与人力资源部）：今日概览统计 + 我处理中的事项 + 事务入口。
// 数据来自服务端按「今天」动态计算（hrTaskSummaryProvider），任务软认领见 ADR-021。
// 子页面：/hr/tasks/:type（转正办理/生日关怀/入职周年/新近入职）。
// 文档：docs/03-页面/HR任务中心.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../models/hr_task_summary.dart';
import '../providers/hr_task_summary_provider.dart';
import '../widgets/hr_task_widgets.dart';

class HrWorkbenchPage extends ConsumerWidget {
  const HrWorkbenchPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(hrTaskSummaryProvider);
    final isCompact = context.breakpoint.isCompact;
    final canPublish = ref.watch(isSuperAdminProvider) ||
        ref.watch(currentPermissionsProvider).contains(Perm.noticePublish);

    Widget body = async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => UtenEmpty.error(
        message: '加载工作台失败，请稍后重试',
        actionLabel: '重试',
        onAction: () =>
            ref.read(hrTaskSummaryProvider.notifier).refresh(),
      ),
      data: (s) => RefreshIndicator(
        onRefresh: () =>
            ref.read(hrTaskSummaryProvider.notifier).refresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            _overview(context, s, isCompact),
            _myClaims(context, s),
            _entries(context, s, isCompact),
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
            onPressed: () =>
                ref.read(hrTaskSummaryProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: body,
    );
  }

  // ---- 今日概览：4 张统计卡，点击进对应子页 ----
  // 左对齐 KPI 卡：彩色图标色块（左上）+ 大数字（主）+ 说明（底）；count=0 整卡
  // 弱化为中性灰、>0 时鲜活——一眼分清有无待办。强调色低饱和、与 teal 主题协调。
  Widget _overview(BuildContext context, HrTaskSummary s, bool isCompact) {
    final cards = [
      (HrTaskType.confirm, s.confirmToday.length + s.confirmOverdue.length, '今日/逾期', const Color(0xFF0D9488)),
      (HrTaskType.birthday, s.birthdayToday.length, '今日生日', const Color(0xFFDB2777)),
      (HrTaskType.anniversary, s.anniversaryToday.length, '今日周年', const Color(0xFFD97706)),
      (HrTaskType.newhire, s.newHires.length, '近 30 天', const Color(0xFF059669)),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenSpacing.s12,
        0,
      ),
      child: GridView.count(
        crossAxisCount: isCompact ? 2 : 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: UtenSpacing.s8,
        crossAxisSpacing: UtenSpacing.s8,
        childAspectRatio: isCompact ? 1.25 : 1.55,
        children: [
          for (final (type, count, caption, accent) in cards)
            _StatCard(
              type: type,
              count: count,
              caption: caption,
              accent: accent,
              onTap: () => context.push(RouteName.hrTaskList(type.taskType)),
            ),
        ],
      ),
    );
  }

  // ---- 快捷发布祝福：点类型瓦片直达通知发布页并预填对应类型模板 ----
  Widget _quickNotice(BuildContext context, bool isCompact) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    String publishWith(String type) => '${RouteName.noticePublish}?type=$type';
    final tiles = <(IconData, Color, String, VoidCallback)>[
      (
        Icons.campaign_rounded,
        const Color(0xFF14B8A6),
        l10n.noticeQuickPublish,
        () => context.push(RouteName.noticePublish),
      ),
      (
        Icons.cake_rounded,
        const Color(0xFFF43F5E),
        l10n.noticeQuickBirthday,
        () => context.push(publishWith('birthday')),
      ),
      (
        Icons.emoji_events_rounded,
        const Color(0xFFF59E0B),
        l10n.noticeQuickAnniversary,
        () => context.push(publishWith('anniversary')),
      ),
      (
        Icons.favorite_rounded,
        const Color(0xFFD946EF),
        l10n.noticeQuickWedding,
        () => context.push(publishWith('wedding')),
      ),
      (
        Icons.child_care_rounded,
        const Color(0xFF38BDF8),
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
            crossAxisCount: isCompact ? 3 : 5,
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
    return Card(
      margin: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenSpacing.s12,
        0,
      ),
      clipBehavior: Clip.antiAlias,
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
            HrTaskTile(type: mine[i].$1, item: mine[i].$2),
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

  // ---- 事务入口：四个子页面 ----
  Widget _entries(BuildContext context, HrTaskSummary s, bool isCompact) {
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
      (
        HrTaskType.newhire,
        '${s.newHires.length} 人近 30 天入职',
        '适应期跟进，7 天内高亮',
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
            Card(
              margin: const EdgeInsets.only(bottom: UtenSpacing.s12),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                onTap: () =>
                    context.push(RouteName.hrTaskList(type.taskType)),
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
              '请在员工档案中补录（编辑员工 → 转正日期）。',
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

/// 今日概览统计卡：彩色图标色块 + 大数字 + 说明。
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
    // count=0 整卡弱化为中性灰（色块更淡、数字变灰）；>0 用强调色，鲜活醒目。
    final active = count > 0;
    final color = active ? accent : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      label: '${type.title}，$count，$caption',
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: active ? 0.14 : 0.08),
                    borderRadius: UtenRadius.lgAll,
                  ),
                  child: Icon(type.icon, size: 20, color: color),
                ),
                const Spacer(),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '$count',
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.05,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
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
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s8),
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
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
