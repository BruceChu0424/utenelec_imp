// 报销列表页（卡片网格版）
// 文档：docs/03-页面/报销列表页.md
//
// 响应式：compact 由页面自套 UtenContentContainer（gutter 16）；
// medium+ 外壳（MainShellPage）已收敛内容区，页面不再重复套容器

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_list_create_action.dart';
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
import '../models/expense_claim.dart';
import '../providers/expense_providers.dart';

class ExpenseListPage extends ConsumerWidget {
  const ExpenseListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(expenseListProvider);
    final filter = ref.watch(expenseFilterProvider);
    final createAction = UtenListCreateAction(
      emptyIcon: Icons.receipt_long_outlined,
      emptyMessage: '暂无报销单',
      emptyDescription: '新建第一笔报销，提交后可在这里跟踪处理进度',
      emptyActionLabel: '新建报销',
      fabLabel: '新建报销',
      actionIcon: Icons.add_rounded,
      onPressed: () => context.go(RouteName.expenseNew),
    );

    // compact 自套容器补 gutter；medium+ 外壳已收敛，避免双层 gutter
    Widget body = Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.read(expenseListProvider.notifier).refresh(),
            child: list.when(
              loading: () => const UtenSkeletonList(itemCount: 6),
              error: (e, _) => UtenEmpty.error(
                message: '加载失败：$e',
                actionLabel: '重试',
                onAction: () => ref.invalidate(expenseListProvider),
              ),
              data: (page) {
                final claims = page.items;
                if (claims.isEmpty) {
                  return createAction.emptyState(topSpacing: 80);
                }
                return SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  // 底部多留白：内容滚到底可越过悬浮 FAB
                  padding: const EdgeInsets.only(
                    top: UtenSpacing.s16,
                    bottom: 96,
                  ),
                  child: Column(
                    children: [
                      UtenResponsiveGrid(
                        itemCount: claims.length,
                        itemBuilder: (context, i, _) => _ClaimCard(
                          claim: claims[i],
                          onTap: () => context.push(
                            RoutePath.expenseDetail(claims[i].id),
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
                                    .read(expenseListProvider.notifier)
                                    .previousPage()
                              : null,
                          onNext: !list.isLoading && page.page < page.totalPages
                              ? () => ref
                                    .read(expenseListProvider.notifier)
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
        title: '报销',
        showBackButton: true,
        centerWidget: UtenSegmentedFilter<ExpenseFilter>(
          selected: filter,
          onChanged: (v) => ref.read(expenseFilterProvider.notifier).state = v,
          segments: const [
            UtenSegment(value: ExpenseFilter.all, label: '全部'),
            UtenSegment(value: ExpenseFilter.draft, label: '草稿'),
            UtenSegment(value: ExpenseFilter.processing, label: '处理中'),
            UtenSegment(value: ExpenseFilter.finished, label: '已完成'),
          ],
        ),
      ),
      floatingActionButton: createAction.floatingActionButton(
        context,
        hasItems: list.valueOrNull?.items.isNotEmpty ?? false,
      ),
      body: body,
    );
  }
}

/// 报销卡片（竖版）
class _ClaimCard extends StatelessWidget {
  const _ClaimCard({required this.claim, required this.onTap});
  final ExpenseClaim claim;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return UtenCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 状态徽章
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _statusColor(claim.status).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _statusIcon(claim.status),
                  color: _statusColor(claim.status),
                  size: 20,
                ),
              ),
              UtenStatusBadge(
                label: claim.status.label,
                type: _badgeType(claim.status),
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          // 标题
          Text(
            claim.title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: UtenSpacing.s4),
          // 副信息
          Text(
            '${_fmtDate(claim.createdAt)}  ·  ${claim.items.length} 项明细',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          const Divider(),
          const SizedBox(height: UtenSpacing.s12),
          // 金额（突出）
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '报销总额',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                '¥ ${claim.totalAmount.toStringAsFixed(2)}',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _statusIcon(ExpenseClaimStatus s) => switch (s) {
    ExpenseClaimStatus.draft => Icons.edit_note_rounded,
    ExpenseClaimStatus.submitted => Icons.send_rounded,
    ExpenseClaimStatus.reviewing => Icons.pending_actions_rounded,
    ExpenseClaimStatus.approved => Icons.check_circle_outline_rounded,
    ExpenseClaimStatus.rejected => Icons.cancel_outlined,
    ExpenseClaimStatus.paid => Icons.account_balance_wallet_rounded,
  };

  Color _statusColor(ExpenseClaimStatus s) => switch (s) {
    ExpenseClaimStatus.draft => UtenColors.slate500,
    ExpenseClaimStatus.submitted => UtenColors.info,
    ExpenseClaimStatus.reviewing => UtenColors.warning,
    ExpenseClaimStatus.approved => UtenColors.teal600,
    ExpenseClaimStatus.rejected => UtenColors.error,
    ExpenseClaimStatus.paid => UtenColors.success,
  };

  UtenStatusBadgeType _badgeType(ExpenseClaimStatus s) => switch (s) {
    ExpenseClaimStatus.draft => UtenStatusBadgeType.neutral,
    ExpenseClaimStatus.submitted => UtenStatusBadgeType.info,
    ExpenseClaimStatus.reviewing => UtenStatusBadgeType.warning,
    ExpenseClaimStatus.approved => UtenStatusBadgeType.accent,
    ExpenseClaimStatus.rejected => UtenStatusBadgeType.danger,
    ExpenseClaimStatus.paid => UtenStatusBadgeType.success,
  };

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
