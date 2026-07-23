// DashboardPage - 工作台首页（v2 - 大厂仪表盘范）
// 文档：docs/03-页面/工作台首页.md
//
// 设计原则（ui-ux-pro-max）：
// - 信息密度高，去花哨装饰
// - KPI 卡片网格 + 待办清单 + 快捷操作
// - 区块靠卡片分隔，不靠渐变
// - 颜色克制：中性为主，品牌色仅点缀

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/cards/uten_stat_card.dart';
import '../../../components/data_display/uten_user_avatar.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../features/notice/providers/notice_providers.dart';
import '../../../shared/providers/session_provider.dart';

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _staggerController;

  final _stats = <_StatData>[
    _StatData(
      title: '今日产量',
      value: 1234,
      unit: '件',
      icon: Icons.factory_rounded,
      trend: UtenTrend.up,
      trendPercent: 12.5,
      color: UtenColors.teal600,
    ),
    _StatData(
      title: '当前库存',
      value: 8945,
      unit: '件',
      icon: Icons.inventory_2_rounded,
      trend: UtenTrend.down,
      trendPercent: 3.2,
      color: UtenColors.info,
    ),
    _StatData(
      title: '在线员工',
      value: 286,
      unit: '人',
      icon: Icons.people_alt_rounded,
      trend: UtenTrend.up,
      trendPercent: 5.8,
      color: UtenColors.success,
    ),
    _StatData(
      title: '待办事项',
      value: 18,
      unit: '项',
      icon: Icons.task_alt_rounded,
      trend: UtenTrend.down,
      trendPercent: 8.0,
      color: UtenColors.warning,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _staggerController = AnimationController(
      vsync: this,
      duration: UtenAnim.slow,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _staggerController.forward();
    });
  }

  @override
  void dispose() {
    _staggerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = ref.watch(sessionProvider);
    final theme = Theme.of(context);

    _stats[0].title = l10n.statTodayOutput;
    _stats[0].unit = l10n.statOutputUnit;
    _stats[1].title = l10n.statInventory;
    _stats[2].title = l10n.statOnlineEmployees;
    _stats[3].title = l10n.statPendingTodos;

    final name = session.user?.name ?? 'Uten';
    final unreadCount = ref.watch(unreadNoticeCountProvider).valueOrNull ?? 0;

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildPageHeader(theme, name, unreadCount),
              const SizedBox(height: 24),
              _buildSectionHeader(theme, l10n.dashboardTodayStats),
              const SizedBox(height: 12),
              _buildStatGrid(theme),
              const SizedBox(height: 28),
              _buildSectionHeader(theme, l10n.dashboardQuickActions),
              const SizedBox(height: 12),
              _buildQuickActions(theme),
              const SizedBox(height: 28),
              _buildSectionHeader(theme, '待办事项'),
              const SizedBox(height: 12),
              _buildTodoList(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPageHeader(ThemeData theme, String name, int unreadCount) {
    return Row(
      children: [
        UtenUserAvatar(name: name),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '你好，$name',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _formatDate(DateTime.now()),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Badge(
          label: Text(unreadCount > 99 ? '99+' : '$unreadCount'),
          isLabelVisible: unreadCount > 0,
          child: IconButton(
            icon: const Icon(Icons.notifications_none_rounded),
            onPressed: () => context.go(RouteName.notice),
            tooltip: unreadCount > 0 ? '通知 · $unreadCount 条未读' : '通知',
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: [
          Text(
            text,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatGrid(ThemeData theme) {
    return UtenResponsiveGrid(
      itemCount: _stats.length,
      itemBuilder: (context, i, itemWidth) {
        return AnimatedBuilder(
          animation: _staggerController,
          builder: (context, child) {
            final intervalBegin = (i * 0.08).clamp(0.0, 0.8);
            final intervalEnd = (intervalBegin + 0.2).clamp(0.0, 1.0);
            final t = Interval(
              intervalBegin,
              intervalEnd,
              curve: Curves.easeOut,
            ).transform(_staggerController.value);
            return Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, (1 - t) * 16),
                child: child,
              ),
            );
          },
          child: UtenStatCard(
            title: _stats[i].title,
            value: _stats[i].value,
            unit: _stats[i].unit,
            icon: _stats[i].icon,
            iconColor: _stats[i].color,
            trend: _stats[i].trend,
            trendPercent: _stats[i].trendPercent,
          ),
        );
      },
    );
  }

  Widget _buildQuickActions(ThemeData theme) {
    final actions = <_QuickAction>[
      const _QuickAction(
        icon: Icons.receipt_long_rounded,
        label: '我的报销',
        color: UtenColors.teal600,
        path: RouteName.expense,
      ),
      const _QuickAction(
        icon: Icons.account_balance_wallet_rounded,
        label: '工资条',
        color: UtenColors.info,
        path: RouteName.payrollSlipList,
      ),
      const _QuickAction(
        icon: Icons.campaign_rounded,
        label: '公司通知',
        color: UtenColors.warning,
        path: RouteName.notice,
      ),
      const _QuickAction(
        icon: Icons.lightbulb_outline_rounded,
        label: '建议箱',
        color: UtenColors.success,
        path: RouteName.suggestion,
      ),
    ];

    return UtenResponsiveGrid(
      itemCount: actions.length,
      spacing: 12,
      itemBuilder: (context, i, itemWidth) =>
          _QuickActionTile(action: actions[i]),
    );
  }

  Widget _buildTodoList(ThemeData theme) {
    final todos = <_Todo>[
      const _Todo(
        title: '6 月工资条待确认',
        subtitle: '人事部 · 2 天前',
        status: '待查看',
        statusColor: UtenColors.warning,
        path: RouteName.payrollSlipList,
      ),
      const _Todo(
        title: '报销单待审批',
        subtitle: '上海客户拜访差旅 · 3 天前',
        status: '处理中',
        statusColor: UtenColors.info,
        path: RouteName.expense,
      ),
      const _Todo(
        title: '本周六设备检修通知',
        subtitle: '生产部 · 紧急',
        status: '未读',
        statusColor: UtenColors.error,
        path: RouteName.notice,
      ),
    ];

    return UtenCard(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          for (var i = 0; i < todos.length; i++) ...[
            _TodoTile(todo: todos[i]),
            if (i != todos.length - 1)
              const Divider(height: 1, indent: 56, endIndent: 16),
          ],
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final w = weekdays[date.weekday - 1];
    return '${date.year}年${date.month}月${date.day}日 · $w';
  }
}

class _StatData {
  _StatData({
    required this.title,
    required this.value,
    required this.unit,
    required this.icon,
    required this.trend,
    required this.trendPercent,
    required this.color,
  });

  String title;
  final num value;
  String unit;
  final IconData icon;
  final UtenTrend trend;
  final double trendPercent;
  final Color color;
}

class _QuickAction {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.path,
  });
  final IconData icon;
  final String label;
  final Color color;
  final String path;
}

class _QuickActionTile extends StatelessWidget {
  const _QuickActionTile({required this.action});
  final _QuickAction action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.go(action.path),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: action.color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(action.icon, color: action.color, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  action.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Todo {
  const _Todo({
    required this.title,
    required this.subtitle,
    required this.status,
    required this.statusColor,
    required this.path,
  });
  final String title;
  final String subtitle;
  final String status;
  final Color statusColor;
  final String path;
}

class _TodoTile extends StatelessWidget {
  const _TodoTile({required this.todo});
  final _Todo todo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => context.go(todo.path),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: todo.statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.circle, color: todo.statusColor, size: 8),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      todo.title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      todo.subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: todo.statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  todo.status,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: todo.statusColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
