import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_lazy_mount.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../notice/widgets/celebration_today_card.dart';
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
    final overview = ref.watch(dashboardOverviewProvider);
    return overview.when(
      loading: () => const _DashboardOverviewSkeleton(),
      error: (error, _) =>
          _ErrorCard(onRetry: () => ref.invalidate(dashboardOverviewProvider)),
      data: (data) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 2026-09-28 合并改版：今日概览与待办任务从两段独立区块（各自
          // UtenConsoleHeader + 面板）并入同一块控制台面板——标题栏 / 指标区 /
          // 待办区，见 dashboard_console_sections.dart 的 DashboardOverviewPanel。
          DashboardOverviewPanel(
            metrics: data.metrics,
            todos: data.todos,
            departmentName: data.departmentName,
            generatedAt: data.generatedAt,
            // 今日庆典卡（当前用户本人生日/周年/新婚/新生儿；无则不渲染）插在
            // 面板标题栏与指标区之间。数据来自 myCelebrationTodayProvider（PII 安全）。
            celebration: const CelebrationTodayCard(),
          ),
        ],
      ),
    );
  }
}

// 旧的卡片堆实现（_MetricGrid / _MetricContent / _TodoList / _TodoCard）已于
// 2026-09-12 随控制台改版删除；2026-09-28 两段区块合并为单一面板后，
// DashboardMetricStrip / DashboardTodoLane / UtenConsoleHeader 也随之退役，
// 现行形态在 dashboard_console_sections.dart（DashboardOverviewPanel）。
// 骨架屏与错误态仍留在本文件，与真实形态共用；空态由面板各区各自承担
//（指标区/待办区的空态要说清「本部门」，与旧的通用空卡文案不同）。

/// 概览骨架占位：与 DashboardOverviewPanel 同构——标题栏 + 「横向指标带 │
/// 竖线 │ 待办区」(宽屏并排 / 窄屏堆叠)。
/// LazyMount 首帧占位 与 _DashboardOverviewBody 的 loading 分支共用，视觉连续无闪烁。
class _DashboardOverviewSkeleton extends StatelessWidget {
  const _DashboardOverviewSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const strip = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s12,
      ),
      child: Wrap(
        spacing: UtenSpacing.s24,
        runSpacing: UtenSpacing.s12,
        children: [_StripMetricSkeleton(), _StripMetricSkeleton()],
      ),
    );
    const todoSide = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            UtenSpacing.s16,
            UtenSpacing.s12,
            UtenSpacing.s16,
            UtenSpacing.s4,
          ),
          child: Row(
            children: [
              UtenSkeleton(width: 96, height: 14),
              Spacer(),
              UtenSkeleton(width: 20, height: 20, borderRadius: 10),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            UtenSpacing.s16,
            0,
            UtenSpacing.s16,
            UtenSpacing.s16,
          ),
          child: _TodoTilesSkeleton(),
        ),
      ],
    );
    return UtenConsolePanel(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            color: colors.surfaceContainerLow,
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s16,
              vertical: UtenSpacing.s12,
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    UtenSkeleton(width: 120, height: 18),
                    Spacer(),
                    UtenSkeleton(width: 64, height: 12),
                  ],
                ),
                SizedBox(height: UtenSpacing.s4),
                UtenSkeleton(width: 200, height: 12),
              ],
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 900) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    strip,
                    Divider(height: 1, color: colors.outlineVariant),
                    todoSide,
                  ],
                );
              }
              // 分隔线 = 待办区左缘边框（与真实面板同法；不能 IntrinsicHeight，
              // 骨架瓦片同样含 LayoutBuilder）。
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth / 2,
                    ),
                    child: strip,
                  ),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: colors.outlineVariant.withValues(alpha: .6),
                          ),
                        ),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.only(left: UtenSpacing.s16),
                        child: todoSide,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StripMetricSkeleton extends StatelessWidget {
  const _StripMetricSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        UtenSkeleton(width: 80, height: 12),
        SizedBox(height: UtenSpacing.s8),
        UtenSkeleton(width: 60, height: 24),
        SizedBox(height: UtenSpacing.s4),
        UtenSkeleton(width: 120, height: 10),
      ],
    );
  }
}

class _TodoTilesSkeleton extends StatelessWidget {
  const _TodoTilesSkeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth >= 640
            ? (constraints.maxWidth - UtenSpacing.s12) / 2
            : constraints.maxWidth;
        return Row(
          children: [
            SizedBox(width: width, child: const _TodoTileSkeleton()),
            if (constraints.maxWidth >= 640) ...[
              const SizedBox(width: UtenSpacing.s12),
              SizedBox(width: width, child: const _TodoTileSkeleton()),
            ],
          ],
        );
      },
    );
  }
}

class _TodoTileSkeleton extends StatelessWidget {
  const _TodoTileSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: UtenRadius.controlAll,
      ),
      child: const Padding(
        padding: EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                UtenSkeleton(width: 24, height: 18),
                SizedBox(width: UtenSpacing.s8),
                Expanded(child: UtenSkeleton(height: 14)),
                SizedBox(width: UtenSpacing.s8),
                UtenSkeleton(width: 20, height: 20, borderRadius: 10),
              ],
            ),
            SizedBox(height: UtenSpacing.s8),
            UtenSkeleton(height: 12),
          ],
        ),
      ),
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

/// 指标/待办的语气色。控制台形态（dashboard_console_sections.dart）与旧卡片形态
/// 共用这一份，避免两套口径各自漂移。
Color dashboardToneColor(ThemeData theme, String tone) => switch (tone) {
  'danger' => theme.colorScheme.error,
  'warning' => UtenColors.warningText,
  'success' => UtenColors.successText,
  'info' => theme.colorScheme.primary,
  _ => theme.colorScheme.onSurfaceVariant,
};
