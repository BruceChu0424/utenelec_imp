// 销售订货单「排产进度」面板——销售端看业务链另一端。
//
// 数据源 GET /sales/orders/{id}/plan-progress：每行 订货/可发/已排/已产/已发 + 链路状态
// + 关联生产计划溯源（plan_order_item_links；含合并排产预建的草稿计划，标「草稿」）。
// 有计划查看权限（production_plan:view）时点计划单号/执行子计划可跳生产计划详情。
//
// 2026-08-19 起由模态底表改为内嵌面板（SalesPlanProgressPanel），
// 在「订单进度详情页」中作为产品进度区使用（弹窗已下线，见该页文档）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/progress_ratio.dart';
import '../models/sales_doc.dart';
import '../repositories/sales_repository.dart';

/// 按单排产进度面板（内嵌整页使用；自带加载/错误/空态）。
class SalesPlanProgressPanel extends ConsumerWidget {
  const SalesPlanProgressPanel({super.key, required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<OrderPlanProgressLine>>(
      future: ref
          .read(salesRepositoryProvider(SalesDocType.order))
          .planProgress(orderId),
      builder: (_, snap) {
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Text('排产进度加载失败：${snap.error}'),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return _ProgressList(lines: snap.data!);
      },
    );
  }
}

class _ProgressList extends ConsumerWidget {
  const _ProgressList({required this.lines});

  final List<OrderPlanProgressLine> lines;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final canViewPlan =
        ref
            .watch(currentPermissionsProvider)
            .contains(Perm.productionPlanView) ||
        ref.watch(isSuperAdminProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '已排 = 已进生产计划量；已产 = 完工入库量。点击计划单号或执行子计划可查看生产详情。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        if (lines.isEmpty)
          const Padding(
            padding: EdgeInsets.all(UtenSpacing.s24),
            child: Center(child: Text('(无明细)')),
          ),
        for (final l in lines) _lineCard(context, theme, l, canViewPlan),
      ],
    );
  }

  Widget _lineCard(
    BuildContext context,
    ThemeData theme,
    OrderPlanProgressLine l,
    bool canViewPlan,
  ) {
    final chainColor = chainStatusColor(l.chainStatus, theme);
    return Card(
      margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${l.goodsName ?? l.goodsCode ?? '—'}'
                    '${l.spec != null && l.spec!.isNotEmpty ? ' · ${l.spec}' : ''}'
                    '${l.colorName != null ? ' · ${l.colorName}' : ''}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: chainColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    chainStatusLabel(l.chainStatus),
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: chainColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Row(
              children: [
                _num(theme, '订货', l.qty),
                // 问题 #18：审核后销售端不再看"可发"（内部预留口径，容易和客户承诺量混淆），
                // 改在最后展示"剩余"（订货 − 已发，还欠客户多少）。
                _num(theme, '已排', l.plannedQty, highlight: true),
                _num(theme, '已产', l.producedQty, highlight: true),
                _num(theme, '已发', l.shippedQty),
                _num(theme, '剩余', _remaining(l.qty, l.shippedQty)),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            _materialAnalysisProgress(theme, l),
            if (l.links.isNotEmpty) ...[
              const Divider(height: UtenSpacing.s16),
              for (final p in l.links) _planRow(context, theme, p, canViewPlan),
            ] else ...[
              const Divider(height: UtenSpacing.s16),
              Text(
                (l.submittedPlanQty ?? 0) > (l.approvedPlannedQty ?? 0)
                    ? '生产计划已提交待批准，批准后在此显示下达计划'
                    : l.materialAnalysisId != null ||
                          l.materialAnalysisStatus != null
                    ? '已进入物料分析，尚未生成生产计划'
                    : '待物料分析',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _materialAnalysisProgress(
    ThemeData theme,
    OrderPlanProgressLine line,
  ) {
    final submitted = line.submittedPlanQty ?? 0;
    final approved = line.approvedPlannedQty ?? line.plannedQty ?? 0;
    final hasAnalysis =
        line.materialAnalysisId != null ||
        line.materialAnalysisStatus != null ||
        line.analyzedQty != null ||
        line.readyNowQty != null ||
        line.readyByDateQty != null ||
        line.readinessRatio != null ||
        line.submittedPlanQty != null ||
        line.materialAnalyzedAt != null;
    final (label, icon, color) = submitted > approved
        ? ('已提交待批准', Icons.approval_outlined, theme.colorScheme.tertiary)
        : approved > 0
        ? ('已批准下达', Icons.verified_outlined, theme.colorScheme.primary)
        : !hasAnalysis
        ? (
            '待分析',
            Icons.pending_actions_outlined,
            theme.colorScheme.onSurfaceVariant,
          )
        : switch (line.materialAnalysisStatus?.toUpperCase()) {
            'READY' || 'CONFIRMED' => (
              '已齐套，待生成计划',
              Icons.inventory_2_outlined,
              theme.colorScheme.primary,
            ),
            'STALE' => (
              '分析已过期，待刷新',
              Icons.sync_problem_outlined,
              theme.colorScheme.error,
            ),
            _ => (
              '备料中',
              Icons.hourglass_bottom_outlined,
              theme.colorScheme.secondary,
            ),
          };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(UtenRadius.sm),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: UtenSpacing.s4),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (hasAnalysis)
            Text(
              '分析 ${_fmt(line.analyzedQty)} · '
              '当前可生产 ${_fmt(line.readyNowQty)} · '
              '预计可生产 ${_fmt(line.readyByDateQty)} · '
              '齐套 ${_ratio(line.readinessRatio)} · '
              '已提交 ${_fmt(line.submittedPlanQty)} · '
              '已批准 ${_fmt(line.approvedPlannedQty ?? line.plannedQty)}',
              style: theme.textTheme.bodySmall,
            ),
          if (line.materialAnalyzedAt != null)
            Text(
              '最后分析 ${_dateTime(line.materialAnalyzedAt!)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  String _dateTime(String value) =>
      value.replaceFirst('T', ' ').split('.').first;

  String _ratio(double? value) {
    if (value == null) return '—';
    final normalized = normalizeProgressRatio(value);
    return '${(normalized.clamp(0, 1) * 100).toStringAsFixed(0)}%';
  }

  Widget _planRow(
    BuildContext context,
    ThemeData theme,
    OrderPlanLink p,
    bool canViewPlan,
  ) {
    final statusText = p.planStatus == 0
        ? '草稿'
        : p.planStatus == 1
        ? (p.planClosed ? '已审·已结案' : '已审核')
        : '红冲';
    final statusColor = p.planStatus == 0
        ? theme.colorScheme.onSurfaceVariant
        : p.planStatus == 1
        ? Colors.green
        : theme.colorScheme.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => _openProductionPlan(
                    context,
                    planId: p.planId,
                    canViewPlan: canViewPlan,
                  ),
                  child: Text(
                    p.planNo ?? '—',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: canViewPlan ? theme.colorScheme.primary : null,
                      decoration: canViewPlan ? TextDecoration.underline : null,
                    ),
                  ),
                ),
              ),
              Text(
                statusText,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Text(
                '排 ${_fmt(p.allocatedQty)} · 产 ${_fmt(p.producedQty)} · 入 ${_fmt(p.inboundQty)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          for (final segment in p.executionSegments)
            _executionSegmentRow(
              context,
              theme,
              segment,
              planId: p.planId,
              canViewPlan: canViewPlan,
            ),
        ],
      ),
    );
  }

  Widget _executionSegmentRow(
    BuildContext context,
    ThemeData theme,
    OrderExecutionSegmentProgress segment, {
    required String planId,
    required bool canViewPlan,
  }) {
    final statusLabel = switch (segment.status) {
      'READY' => '备料中',
      'WAITING' => '待料',
      'DISPATCHED' => '历史工单备料中',
      'IN_PROGRESS' => '生产中',
      'COMPLETED' => '已完成',
      'CANCELLED' => '已取消',
      'REVERSED' => '已红冲',
      _ => segment.status ?? '未知状态',
    };
    final statusColor = switch (segment.status) {
      'COMPLETED' => theme.colorScheme.primary,
      'WAITING' => theme.colorScheme.tertiary,
      'CANCELLED' || 'REVERSED' => theme.colorScheme.error,
      _ => theme.colorScheme.secondary,
    };
    final assignment = [
      segment.workshopName,
      segment.teamName,
    ].where((value) => value?.isNotEmpty == true).join(' · ');
    final dates = [
      segment.planBeginDate,
      segment.planEndDate,
    ].where((value) => value?.isNotEmpty == true).join(' → ');

    return Semantics(
      button: true,
      enabled: canViewPlan,
      label:
          '${segment.segmentCode ?? '执行子计划'}，$statusLabel，'
          '分摊 ${_fmt(segment.allocatedQty)}，'
          '报工 ${_fmt(segment.reportedQty)}，'
          '入库 ${_fmt(segment.inboundQty)}',
      child: Padding(
        padding: const EdgeInsets.only(top: UtenSpacing.s8),
        child: InkWell(
          borderRadius: BorderRadius.circular(UtenRadius.sm),
          onTap: () => _openProductionPlan(
            context,
            planId: planId,
            canViewPlan: canViewPlan,
            executionSegmentId: segment.executionSegmentId,
          ),
          child: Container(
            padding: const EdgeInsets.all(UtenSpacing.s8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(UtenRadius.sm),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        segment.segmentCode ?? '执行子计划',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      statusLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: statusColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    Icon(
                      canViewPlan
                          ? Icons.chevron_right_rounded
                          : Icons.lock_outline_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '分摊 ${_fmt(segment.allocatedQty)} · '
                  '报工 ${_fmt(segment.reportedQty)} · '
                  '入库 ${_fmt(segment.inboundQty)}',
                  style: theme.textTheme.bodySmall,
                ),
                if (assignment.isNotEmpty || dates.isNotEmpty)
                  Text(
                    [
                      assignment,
                      dates,
                    ].where((value) => value.isNotEmpty).join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (segment.delayed)
                  Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: UtenSpacing.s4),
                      Expanded(
                        child: Text(
                          segment.delayReason ?? '已超过计划完工日期',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openProductionPlan(
    BuildContext context, {
    required String planId,
    required bool canViewPlan,
    String? executionSegmentId,
  }) async {
    if (!canViewPlan) {
      context.appWarning('当前账号没有生产计划查看权限', force: true);
      return;
    }
    final normalizedPlanId = planId.trim();
    if (normalizedPlanId.isEmpty) {
      context.appWarning('未找到可打开的生产计划', force: true);
      return;
    }
    final router = GoRouter.of(context);
    final location = Uri(
      path: RoutePath.productionPlanDetail(normalizedPlanId),
      queryParameters: executionSegmentId == null
          ? null
          : {'executionSegmentId': executionSegmentId},
    ).toString();
    try {
      await router.push(location);
    } catch (_) {
      if (context.mounted) {
        context.appError('生产计划打开失败，请稍后重试', force: true);
      }
    }
  }

  /// 剩余 = 订货 − 已发（还欠客户多少，负数/缺失一律按 0 处理）。
  double? _remaining(double? qty, double? shipped) {
    if (qty == null) return null;
    final left = qty - (shipped ?? 0);
    return left > 0 ? left : 0;
  }

  Widget _num(
    ThemeData theme,
    String label,
    double? v, {
    bool highlight = false,
  }) {
    return Expanded(
      child: Column(
        children: [
          Text(
            _fmt(v),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: highlight ? FontWeight.w700 : FontWeight.w400,
              color: highlight ? theme.colorScheme.primary : null,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(double? v) => v == null
      ? '—'
      : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2));
}
