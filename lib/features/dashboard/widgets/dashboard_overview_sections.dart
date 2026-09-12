import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_notification_badge.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_lazy_mount.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../notice/widgets/celebration_today_card.dart';
import '../models/dashboard_overview.dart';
import 'dashboard_console_sections.dart';
import 'uten_console_panel.dart';
import '../providers/dashboard_overview_provider.dart';

class DashboardOverviewSections extends StatelessWidget {
  const DashboardOverviewSections({super.key});

  @override
  Widget build(BuildContext context) {
    // 延迟挂载：首帧只画骨架、不 watch dashboardOverviewProvider、不发那个重聚合
    // 请求；首帧绘制完后再构建 _DashboardOverviewBody 并行加载，避免进工作台时卡顿。
    // 范式同全项目 addPostFrameCallback「首帧让路」惯例。
    return UtenLazyMount(
      placeholder: (_) => const _DashboardOverviewSkeleton(),
      builder: (_) => const _DashboardOverviewBody(),
    );
  }
}

/// 概览数据体（首帧后才挂载）：watch dashboardOverviewProvider；loading 时仍用骨架，
/// 与 LazyMount 首帧占位视觉一致、无闪烁切换。
class _DashboardOverviewBody extends ConsumerWidget {
  const _DashboardOverviewBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final overview = ref.watch(dashboardOverviewProvider);
    return overview.when(
      loading: () => const _DashboardOverviewSkeleton(),
      error: (error, _) =>
          _ErrorCard(onRetry: () => ref.invalidate(dashboardOverviewProvider)),
      data: (data) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 2026-09-12 改版：这两块从「卡片堆 + 折叠列表」换成控制台形态
          // （指标带 / 待办泳道），见 dashboard_console_sections.dart 的设计说明。
          UtenConsoleHeader(
            title: '今日概览',
            // 口径文案同步改正：范围本来就该是「本部门」，此前写「按本人权限展示」
            // 与实际口径不符，也正是用户指出的问题。
            subtitle: data.departmentName.isEmpty
                ? '按本部门范围展示'
                : '${data.departmentName} · 按本部门范围展示',
            accentColor: theme.colorScheme.primary,
            trailing: Text(
              _sampledAt(data.generatedAt),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          // 今日庆典卡片（当前用户本人生日/周年/新婚/新生儿；无则不渲染）置顶，
          // 位于指标带之前。数据来自 myCelebrationTodayProvider（PII 安全）。
          const CelebrationTodayCard(),
          DashboardMetricStrip(
            metrics: data.metrics,
            departmentName: data.departmentName,
            // generatedAt 每次取数都变：数据到达（含手动刷新）时面板重扫一次光。
            // provider 不轮询，这里不会变成循环动画。
            sweepTrigger: data.generatedAt.millisecondsSinceEpoch,
          ),
          const SizedBox(height: UtenSpacing.s24),
          UtenConsoleHeader(
            title: '待办任务',
            subtitle: data.departmentName.isEmpty
                ? '本部门待办，按紧急度排布'
                : '${data.departmentName} · 按紧急度排布',
            accentColor: theme.colorScheme.primary,
            // 总数徽章 = 各待办 count 之和（无待办时徽章自身不渲染）。
            trailing: UtenNotificationBadge(
              count: data.todos.fold<int>(0, (sum, t) => sum + t.count),
              size: 20,
              showLabel: true,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          DashboardTodoLane(
            todos: data.todos,
            departmentName: data.departmentName,
            sweepTrigger: data.generatedAt.millisecondsSinceEpoch,
          ),
          if (data.intelligence.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s24),
            UtenSectionHeader(
              title: '政策与监管动态',
              accentColor: theme.colorScheme.primary,
              trailing: const Text('仅收录政府官网'),
            ),
            const SizedBox(height: UtenSpacing.s12),
            _PolicyList(items: data.intelligence),
          ],
        ],
      ),
    );
  }
}

// 旧的卡片堆实现（_MetricGrid / _MetricContent / _TodoList / _TodoCard）已于
// 2026-09-12 随控制台改版删除，不留死代码：新形态在
// dashboard_console_sections.dart（DashboardMetricStrip / DashboardTodoLane）。
// 骨架屏与错误态仍留在本文件，两种形态共用；空态已由控制台形态各自承担
//（指标带/待办泳道的空态要说清「本部门」，与旧的通用空卡文案不同）。

class _PolicyList extends StatefulWidget {
  const _PolicyList({required this.items});

  final List<PolicyBrief> items;

  @override
  State<_PolicyList> createState() => _PolicyListState();
}

class _PolicyListState extends State<_PolicyList> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 列数随容器宽度实时变化（窗口拉宽/拉窄都会触发 LayoutBuilder 重建），
        // 收起时只展示一行；超出一行的内容通过末尾「加载更多」展开。
        final columns = constraints.maxWidth >= 840 ? 2 : 1;
        final overflow = items.length > columns;
        final visible = _expanded ? items : items.take(columns).toList();
        final hiddenCount = items.length - visible.length;
        return Column(
          children: [
            if (columns == 1)
              Column(
                children: [
                  for (var i = 0; i < visible.length; i++) ...[
                    _PolicyCard(item: visible[i]),
                    if (i != visible.length - 1)
                      const SizedBox(height: UtenSpacing.s8),
                  ],
                ],
              )
            else
              Wrap(
                spacing: UtenSpacing.s12,
                runSpacing: UtenSpacing.s12,
                children: [
                  for (final item in visible)
                    SizedBox(
                      width: (constraints.maxWidth - UtenSpacing.s12) / 2,
                      child: _PolicyCard(item: item),
                    ),
                ],
              ),
            if (overflow) ...[
              const SizedBox(height: UtenSpacing.s8),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                  label: Text(_expanded ? '收起' : '加载更多(还有 $hiddenCount 条)'),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _PolicyCard extends StatelessWidget {
  const _PolicyCard({required this.item});

  final PolicyBrief item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: '${item.title}，来源 ${item.sourceName}',
      child: UtenCard(
        onTap: () => _showPolicyDetail(context, item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _CategoryBadge(category: item.category),
                const Spacer(),
                Text(
                  _date(item.publishedOn),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              item.summary,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            Row(
              children: [
                const Icon(Icons.verified_outlined, size: 16),
                const SizedBox(width: UtenSpacing.s4),
                Expanded(
                  child: Text(
                    item.sourceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                const Icon(Icons.open_in_new_rounded, size: 16),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryBadge extends StatelessWidget {
  const _CategoryBadge({required this.category});

  final String category;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: UtenRadius.pillAll,
      ),
      child: Text(
        _categoryLabel(category),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 概览骨架占位：今日概览（一行指标灰卡）+ 待办任务（灰卡网格）。
/// LazyMount 首帧占位 与 _DashboardOverviewBody 的 loading 分支共用，视觉连续无闪烁。
/// 政策与监管动态段按真实数据非空才渲染，骨架省略其占位，避免无数据时「先显后隐」。
class _DashboardOverviewSkeleton extends StatelessWidget {
  const _DashboardOverviewSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UtenSectionHeader(title: '今日概览'),
        SizedBox(height: UtenSpacing.s12),
        _MetricSkeleton(),
        SizedBox(height: UtenSpacing.s24),
        UtenSectionHeader(title: '待办任务'),
        SizedBox(height: UtenSpacing.s12),
        _TodoSkeleton(),
      ],
    );
  }
}

class _MetricSkeleton extends StatelessWidget {
  const _MetricSkeleton();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s12,
      children: [
        for (var i = 0; i < 4; i++)
          const SizedBox(
            width: 220,
            child: UtenCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UtenSkeleton(width: 80, height: 12),
                  SizedBox(height: UtenSpacing.s12),
                  UtenSkeleton(width: 120, height: 22),
                  SizedBox(height: UtenSpacing.s4),
                  UtenSkeleton(height: 12),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _TodoSkeleton extends StatelessWidget {
  const _TodoSkeleton();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s12,
      children: [
        for (var i = 0; i < 2; i++)
          const SizedBox(
            width: 220,
            child: UtenCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UtenSkeleton(width: 80, height: 12),
                  SizedBox(height: UtenSpacing.s12),
                  UtenSkeleton(width: 40, height: 22),
                  SizedBox(height: UtenSpacing.s4),
                  UtenSkeleton(height: 12),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: UtenSpacing.s12),
          const Expanded(child: Text('工作台数据暂时加载失败')),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

Future<void> _showPolicyDetail(BuildContext context, PolicyBrief item) async {
  // 弹窗/底部弹层文字可框选复制（准则 §3.4：独立路由自带局部 region，
  // 与工作台页面的轮询徽章互不影响）。此处包一处，紧凑 sheet 与 Dialog 两分支共用。
  final content = SelectionArea(child: _PolicyDetail(item: item));
  if (context.breakpoint.isCompact) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => content,
    );
  } else {
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: content,
        ),
      ),
    );
  }
}

class _PolicyDetail extends StatelessWidget {
  const _PolicyDetail({required this.item});

  final PolicyBrief item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(UtenSpacing.s24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CategoryBadge(category: item.category),
          const SizedBox(height: UtenSpacing.s12),
          Text(item.title, style: theme.textTheme.titleLarge),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '${item.sourceName} · ${_date(item.publishedOn)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Divider(height: UtenSpacing.s32),
          Text(item.summary, style: theme.textTheme.bodyLarge),
          const SizedBox(height: UtenSpacing.s16),
          Text(
            '提示：摘要用于筛选信息，适用资格、申报期限与材料要求请以官方原文及主管部门答复为准。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s24),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _openOfficialSource(context, item.sourceUrl),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('查看官方原文'),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _openOfficialSource(BuildContext context, String sourceUrl) async {
  final uri = Uri.tryParse(sourceUrl);
  if (uri == null ||
      uri.scheme != 'https' ||
      !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    if (context.mounted) context.appError('无法打开官方原文链接');
  }
}

/// 指标/待办的语气色。控制台形态（dashboard_console_sections.dart）与旧卡片形态
/// 共用这一份，避免两套口径各自漂移。
Color dashboardToneColor(ThemeData theme, String tone) => switch (tone) {
  'danger' => theme.colorScheme.error,
  'warning' => UtenColors.warningText,
  'success' => UtenColors.successText,
  'info' => theme.colorScheme.primary,
  _ => theme.colorScheme.onSurfaceVariant,
};

/// 指标图标。同上：两种形态共用一份。
IconData dashboardMetricIcon(String id) {
  if (id.contains('production')) return Icons.precision_manufacturing_outlined;
  if (id.contains('sales')) return Icons.receipt_long_outlined;
  if (id.contains('notice')) return Icons.notifications_none_rounded;
  if (id.contains('ar-')) return Icons.south_west_rounded;
  if (id.contains('ap-')) return Icons.north_east_rounded;
  return Icons.insights_outlined;
}

String _categoryLabel(String value) => switch (value) {
  'TAX' => '税费',
  'SUBSIDY' => '补贴',
  'EXPORT' => '出口退税',
  'INSPECTION' => '检查',
  'SAFETY' => '安全生产',
  'QUALITY' => '质量监管',
  _ => '政策动态',
};

String _date(DateTime? value) {
  if (value == null) return '日期见原文';
  return '${value.year}-${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

/// 面板右上角的采样时刻（HH:mm），给「这是实时仪表」一个锚点。
String _sampledAt(DateTime value) {
  final local = value.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')} 采样';
}
