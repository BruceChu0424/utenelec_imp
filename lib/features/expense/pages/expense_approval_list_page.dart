// 报销审批列表页（Phase 3）
// 文档：docs/03-页面/报销审批列表页.md
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
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/expense_claim.dart';
import '../providers/expense_providers.dart';

class ExpenseApprovalListPage extends ConsumerWidget {
  const ExpenseApprovalListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(approvalFilterProvider);
    final listAsync = ref.watch(expenseApprovalListProvider);

    // compact 自套容器补 gutter；medium+ 外壳已收敛，避免双层 gutter
    Widget body = Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(
              top: UtenSpacing.s12,
              bottom: UtenSpacing.s8,
            ),
            child: UtenSegmentedFilter<ApprovalFilter>(
              selected: filter,
              onChanged: (v) =>
                  ref.read(approvalFilterProvider.notifier).state = v,
              segments: const [
                UtenSegment(value: ApprovalFilter.mine, label: '待我审'),
                UtenSegment(value: ApprovalFilter.all, label: '全部'),
                UtenSegment(value: ApprovalFilter.done, label: '已审'),
              ],
            ),
          ),
          Expanded(
            child: listAsync.when(
              loading: () => const UtenSkeletonList(itemCount: 4),
              error: (e, _) => UtenEmpty.error(
                message: '加载失败：$e',
                actionLabel: '重试',
                onAction: () => ref.invalidate(expenseApprovalListProvider),
              ),
              data: (all) {
                final list = all.where((c) => filter.matches(c.status)).toList();
                if (list.isEmpty) {
                  return ListView(
                    children: const [
                      SizedBox(height: 80),
                      UtenEmpty(
                        icon: Icons.task_alt_rounded,
                        message: '暂无待审批报销',
                      ),
                    ],
                  );
                }
                return UtenPagedGrid(
                  // 审批队列是公司维度聚合（"全部" tab 无上限），客户端按页切片。
                  items: list,
                  padding: const EdgeInsets.symmetric(
                    vertical: UtenSpacing.s16,
                  ),
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemBuilder: (context, i, _) => _ApprovalCard(
                    claim: list[i],
                    onTap: () => context.go('/expense/approval/${list[i].id}'),
                  ),
                );
              },
            ),
          ),
        ],
      );
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: const UtenAppBar(title: '报销审批', showBackButton: true),
      body: body,
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.claim, required this.onTap});
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
          Row(
            children: [
              const CircleAvatar(
                radius: 18,
                backgroundColor: UtenColors.teal500,
                child: Icon(Icons.person, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(claim.applicantName,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Text(claim.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              UtenStatusBadge(
                label: claim.status.label,
                type: _badge(claim.status),
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          const Divider(),
          const SizedBox(height: UtenSpacing.s8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${claim.items.length} 项 · ${_fmt(claim.submittedAt ?? claim.createdAt)}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              Text('¥ ${claim.totalAmount.toStringAsFixed(0)}',
                  style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
        ],
      ),
    );
  }
}

UtenStatusBadgeType _badge(ExpenseClaimStatus s) => switch (s) {
      ExpenseClaimStatus.submitted => UtenStatusBadgeType.info,
      ExpenseClaimStatus.reviewing => UtenStatusBadgeType.warning,
      ExpenseClaimStatus.approved => UtenStatusBadgeType.accent,
      ExpenseClaimStatus.rejected => UtenStatusBadgeType.danger,
      ExpenseClaimStatus.paid => UtenStatusBadgeType.success,
      ExpenseClaimStatus.draft => UtenStatusBadgeType.neutral,
    };

String _fmt(DateTime d) =>
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
