// 工资条列表页（卡片网格版）
// 文档：docs/03-页面/工资条列表页.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../models/payroll_slip.dart';
import '../providers/payroll_providers.dart';

class PayrollSlipListPage extends ConsumerWidget {
  const PayrollSlipListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(payrollListProvider);
    final filter = ref.watch(payrollFilterProvider);

    return Scaffold(
      appBar: const UtenAppBar(showBackButton: true),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: UtenSegmentedFilter<PayrollFilter>(
              selected: filter,
              onChanged: (v) =>
                  ref.read(payrollFilterProvider.notifier).state = v,
              segments: const [
                UtenSegment(value: PayrollFilter.all, label: '全部'),
                UtenSegment(value: PayrollFilter.published, label: '已发布'),
                UtenSegment(value: PayrollFilter.viewed, label: '已查看'),
                UtenSegment(value: PayrollFilter.downloaded, label: '已下载'),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.read(payrollListProvider.notifier).refresh(),
              child: list.when(
                loading: () => const UtenSkeletonList(itemCount: 8),
                error: (e, _) => UtenEmpty.error(
                  message: '加载失败：$e',
                  actionLabel: '重试',
                  onAction: () => ref.invalidate(payrollListProvider),
                ),
                data: (slips) {
                  if (slips.isEmpty) {
                    return ListView(
                      children: const [
                        SizedBox(height: 80),
                        UtenEmpty(
                          icon: Icons.account_balance_wallet_outlined,
                          message: '此状态下暂无工资条',
                        ),
                      ],
                    );
                  }
                  // 卡片网格
                  return SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    child: UtenResponsiveGrid(
                      itemCount: slips.length,
                      itemBuilder: (context, i, _) => _SlipCard(
                        slip: slips[i],
                        onTap: () {
                          markPayrollViewed(ref, slips[i].id);
                          context.push(RoutePath.payrollSlipDetail(slips[i].id));
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 工资条卡片（竖版，用于网格）
class _SlipCard extends StatelessWidget {
  const _SlipCard({required this.slip, required this.onTap});
  final PayrollSlip slip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNew = slip.status == PayrollSlipStatus.published;

    return UtenCard(
      onTap: onTap,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 第一行：图标 + 状态徽章
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: (isNew ? UtenColors.warning : UtenColors.teal600)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isNew
                      ? Icons.mark_email_unread_outlined
                      : Icons.receipt_long_rounded,
                  color: isNew ? UtenColors.warning : UtenColors.teal600,
                  size: 20,
                ),
              ),
              UtenStatusBadge(
                label: slip.status.label,
                type: _badgeType(slip.status),
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 第二行：期间
          Text(
            slip.periodLabelZh,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          // 第三行：实发金额（突出）
          Text(
            '实发金额',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '¥ ',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                _formatAmount(slip.netIncome),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                  height: 1,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(),
          const SizedBox(height: 10),
          // 第四行：应发 / 扣除
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _miniStat('应发', '¥${_formatAmount(slip.grossIncome)}',
                  UtenColors.success),
              _miniStat('扣除', '¥${_formatAmount(slip.totalDeduction)}',
                  UtenColors.error),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey[600],
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            color: color,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  String _formatAmount(double v) {
    if (v >= 10000) return '${(v / 10000).toStringAsFixed(2)}万';
    return v.toStringAsFixed(2);
  }

  UtenStatusBadgeType _badgeType(PayrollSlipStatus s) => switch (s) {
        PayrollSlipStatus.pending => UtenStatusBadgeType.neutral,
        PayrollSlipStatus.published => UtenStatusBadgeType.warning,
        PayrollSlipStatus.viewed => UtenStatusBadgeType.accent,
        PayrollSlipStatus.downloaded => UtenStatusBadgeType.success,
      };
}
