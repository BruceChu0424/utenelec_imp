// DashboardPage - 工作台首页（v3 - 响应式收敛 + 区块化视觉）
// 文档：docs/03-页面/工作台首页.md
//
// 设计原则（ui-ux-pro-max）：
// - 信息密度高，去花哨装饰
// - KPI 卡片网格 + 待办清单 + 快捷操作
// - 区块靠卡片分隔，不靠渐变
// - 颜色克制：中性为主，品牌色仅点缀
//
// 响应式：
// - compact：页面自带 UtenContentContainer（水平 gutter 16），
//   底部留白 96，滚到底内容可越过悬浮胶囊导航
// - medium+：外壳（MainShellPage）已提供 UtenContentContainer
//   （maxWidth 1600 居中 + gutter 24/32），页面不再叠加，避免双重 gutter；
//   无胶囊遮挡，底部留白 32

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/cards/uten_stat_card.dart';
import '../../../components/data_display/uten_user_avatar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/session_provider.dart';
import '../widgets/workbench_module_area.dart';

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
    final isCompact = context.breakpoint.isCompact;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPageHeader(theme, name),
        const SizedBox(height: UtenSpacing.s24),
        // 今日统计
        UtenSectionHeader(title: l10n.dashboardTodayStats),
        const SizedBox(height: UtenSpacing.s12),
        _buildStatGrid(theme),
        const SizedBox(height: UtenSpacing.s24),
        // 待办事项
        const UtenSectionHeader(title: '待办事项'),
        const SizedBox(height: UtenSpacing.s12),
        _buildTodoList(theme),
        const SizedBox(height: UtenSpacing.s24),
        // 功能模块区：原侧边栏全部分组迁入，按权限点显隐（各组可折叠）
        const WorkbenchModuleArea(),
      ],
    );

    return Scaffold(
      // 底部留白：compact 96（悬浮胶囊 overlay 不占布局，滚到底可越过胶囊）；
      // medium+ 无胶囊，32 即可
      body: SingleChildScrollView(
        padding: EdgeInsets.only(
          top: UtenSpacing.s20,
          bottom: isCompact ? 96 : UtenSpacing.s32,
        ),
        // compact 由页面自行收敛宽度；medium+ 外壳已套 UtenContentContainer，
        // 再套一层会叠加 gutter，故按断点取舍
        child: isCompact ? UtenContentContainer(child: content) : content,
      ),
    );
  }

  /// 页头：问候语 20px w600 为主层级，日期 13px 三级文字为辅
  Widget _buildPageHeader(ThemeData theme, String name) {
    return Row(
      children: [
        UtenUserAvatar(name: name),
        const SizedBox(width: UtenSpacing.s12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '你好，$name',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                _formatDate(DateTime.now()),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
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
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
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
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s16,
            vertical: UtenSpacing.s12,
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: todo.statusColor.withValues(alpha: 0.1),
                  borderRadius: UtenRadius.mdAll,
                ),
                child: Icon(Icons.circle, color: todo.statusColor, size: 8),
              ),
              const SizedBox(width: UtenSpacing.s12),
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
              const SizedBox(width: UtenSpacing.s12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: todo.statusColor.withValues(alpha: 0.1),
                  borderRadius: UtenRadius.smAll,
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
