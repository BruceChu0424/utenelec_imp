// 工资条列表页（卡片网格版）
// 文档：docs/03-页面/工资条列表页.md
//
// 响应式：compact 由页面自套 UtenContentContainer（gutter 16）；
// medium+ 外壳（MainShellPage）已收敛内容区，页面不再重复套容器

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_paged_grid.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/payroll_slip.dart';
import '../providers/payroll_providers.dart';

class PayrollSlipListPage extends ConsumerWidget {
  const PayrollSlipListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(payrollListProvider);
    final filter = ref.watch(payrollFilterProvider);

    // compact 自套容器补 gutter；medium+ 外壳已收敛，避免双层 gutter
    Widget body = Column(
      children: [
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
              data: (page) {
                final slips = page.items;
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
                return SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(
                    vertical: UtenSpacing.s16,
                  ),
                  child: Column(
                    children: [
                      UtenResponsiveGrid(
                        itemCount: slips.length,
                        itemBuilder: (context, i, _) => _SlipCard(
                          slip: slips[i],
                          onTap: () => context.push(
                            RoutePath.payrollSlipDetail(slips[i].id),
                          ),
                        ),
                      ),
                      if (page.totalPages > 1)
                        UtenGridPager(
                          currentPage: page.page,
                          totalPages: page.totalPages,
                          totalItems: page.total,
                          onPrev: !list.isLoading && page.page > 1
                              ? () => ref
                                    .read(payrollListProvider.notifier)
                                    .previousPage()
                              : null,
                          onNext: !list.isLoading && page.page < page.totalPages
                              ? () => ref
                                    .read(payrollListProvider.notifier)
                                    .nextPage()
                              : null,
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: '工资条',
        showBackButton: true,
        centerWidget: UtenSegmentedFilter<PayrollFilter>(
          selected: filter,
          onChanged: (v) => ref.read(payrollFilterProvider.notifier).state = v,
          segments: const [
            UtenSegment(value: PayrollFilter.all, label: '全部'),
            UtenSegment(value: PayrollFilter.published, label: '未查看'),
            UtenSegment(value: PayrollFilter.viewed, label: '已查看'),
            UtenSegment(value: PayrollFilter.downloaded, label: '已下载'),
          ],
        ),
      ),
      body: body,
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
          const SizedBox(height: UtenSpacing.s16),
          // 第二行：期间
          Text(
            slip.periodLabelZh,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          // 第三行：实发金额（突出）
          Text(
            '实发金额',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
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
          const SizedBox(height: UtenSpacing.s12),
          const Divider(),
          const SizedBox(height: UtenSpacing.s8),
          // 第四行：应发 / 扣除
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _miniStat(
                '应发',
                '¥${_formatAmount(slip.grossIncome)}',
                UtenColors.success,
              ),
              _miniStat(
                '扣除',
                '¥${_formatAmount(slip.totalDeduction)}',
                UtenColors.error,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value, Color color) {
    return Builder(
      builder: (context) {
        final theme = Theme.of(context);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: theme.textTheme.titleSmall?.copyWith(
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        );
      },
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
