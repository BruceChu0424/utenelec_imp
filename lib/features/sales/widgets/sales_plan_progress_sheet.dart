// 销售订货单「排产进度」底表——销售端看业务链另一端。
//
// 数据源 GET /sales/orders/{id}/plan-progress：每行 订货/可发/已排/已产/已发 + 链路状态
// + 关联生产计划溯源（plan_order_item_links；含合并排产预建的草稿计划，标「草稿」）。
// 有计划查看权限（production_plan:view）时点计划单号可跳生产计划详情。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../models/sales_doc.dart';
import '../repositories/sales_repository.dart';

/// 弹排产进度底表（仅订货单）。
void showPlanProgressSheet(
  BuildContext context,
  WidgetRef ref,
  String orderId,
) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(UtenRadius.lg)),
    ),
    builder: (ctx) => DraggableScrollableSheet(
      initialChildSize: 0.7,
      expand: false,
      builder: (_, ctl) => FutureBuilder<List<OrderPlanProgressLine>>(
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
          return _ProgressList(lines: snap.data!, controller: ctl);
        },
      ),
    ),
  );
}

class _ProgressList extends ConsumerWidget {
  const _ProgressList({required this.lines, required this.controller});

  final List<OrderPlanProgressLine> lines;
  final ScrollController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final canViewPlan =
        ref
            .watch(currentPermissionsProvider)
            .contains(Perm.productionPlanView) ||
        ref.watch(isSuperAdminProvider);
    return ListView(
      controller: controller,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      children: [
        Text(
          '排产进度（生产链路溯源）',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        Text(
          '已排 = 已进生产计划量；已产 = 完工入库量。点计划单号可看生产计划详情。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        if (lines.isEmpty)
          const Padding(
            padding: EdgeInsets.all(UtenSpacing.s24),
            child: Center(child: Text('（无明细）')),
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
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
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
                    style: TextStyle(
                      fontSize: 11,
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
                _num(theme, '可发', l.reservedQty),
                _num(theme, '已排', l.plannedQty, highlight: true),
                _num(theme, '已产', l.producedQty, highlight: true),
                _num(theme, '已发', l.shippedQty),
              ],
            ),
            if (l.links.isNotEmpty) ...[
              const Divider(height: UtenSpacing.s16),
              for (final p in l.links) _planRow(context, theme, p, canViewPlan),
            ] else ...[
              const Divider(height: UtenSpacing.s16),
              Text(
                '尚未排产',
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
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: canViewPlan
                  ? () {
                      Navigator.of(context).pop();
                      context.push(RoutePath.productionPlanDetail(p.planId));
                    }
                  : null,
              child: Text(
                p.planNo ?? '—',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: canViewPlan ? theme.colorScheme.primary : null,
                  decoration: canViewPlan ? TextDecoration.underline : null,
                ),
              ),
            ),
          ),
          Text(
            statusText,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: statusColor,
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Text(
            '排 ${_fmt(p.allocatedQty)} · 产 ${_fmt(p.producedQty)} · 入 ${_fmt(p.inboundQty)}',
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
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
            style: TextStyle(
              fontSize: 13,
              fontWeight: highlight ? FontWeight.w700 : FontWeight.normal,
              color: highlight ? theme.colorScheme.primary : null,
            ),
          ),
          Text(
            label,
            style: TextStyle(
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
