// 报销详情页
// 文档：docs/03-页面/报销详情页.md（待写）
//
// 响应式：全断点套 UtenContentContainer.narrow（maxWidth 1120）——
// 外壳只收敛到 1600，详情页需自行钳窄居中

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/expense_claim.dart';
import '../models/expense_item.dart';
import '../providers/expense_providers.dart';
import '../../../shared/attachments/attachment_section.dart';

class ExpenseDetailPage extends ConsumerWidget {
  const ExpenseDetailPage({super.key, required this.claimId});

  final String claimId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(expenseDetailProvider(claimId));

    return Scaffold(
      appBar: const UtenAppBar(title: '报销详情', showBackButton: true),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => UtenEmpty.error(
          message: '加载失败：$e',
          onAction: () => ref.invalidate(expenseDetailProvider(claimId)),
        ),
        data: (claim) => _Content(claim: claim),
      ),
    );
  }
}

class _Content extends ConsumerWidget {
  const _Content({required this.claim});
  final ExpenseClaim claim;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final canSubmit = claim.status == ExpenseClaimStatus.draft;
    final canWithdraw =
        claim.status == ExpenseClaimStatus.submitted ||
        claim.status == ExpenseClaimStatus.reviewing;
    final canDelete = claim.status == ExpenseClaimStatus.draft;

    return Column(
      children: [
        Expanded(
          // narrow 容器：compact 提供 gutter，medium+ 把内容钳到 1120 居中
          child: UtenContentContainer.narrow(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
              children: [
                // 金额 Hero
                _buildHero(theme),
                const SizedBox(height: UtenSpacing.s16),

                // 基本信息
                UtenCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      UtenInfoRow(
                        label: '标题',
                        value: claim.title,
                        isImportant: true,
                      ),
                      UtenInfoRow(label: '申请人', value: claim.applicantName),
                      UtenInfoRow(label: '创建时间', value: _fmt(claim.createdAt)),
                      UtenInfoRow(
                        label: '提交时间',
                        value: _fmt(claim.submittedAt),
                      ),
                      if (claim.approvedAt != null)
                        UtenInfoRow(
                          label: '审批时间',
                          value: _fmt(claim.approvedAt),
                        ),
                      if (claim.paidAt != null)
                        UtenInfoRow(
                          label: '打款时间',
                          value: _fmt(claim.paidAt),
                          showDivider: false,
                        ),
                    ],
                  ),
                ),

                if (claim.remark != null) ...[
                  const SizedBox(height: UtenSpacing.s16),
                  _buildRemark(
                    theme,
                    '备注',
                    claim.remark!,
                    theme.colorScheme.surfaceContainerLow,
                  ),
                ],

                if (claim.rejectReason != null) ...[
                  const SizedBox(height: 12),
                  _buildRemark(
                    theme,
                    '驳回原因',
                    claim.rejectReason!,
                    UtenColors.error.withValues(alpha: 0.08),
                    isWarning: true,
                  ),
                ],

                const SizedBox(height: UtenSpacing.s16),
                // 明细（瀑布流网格：手机 1 列、平板 2 列、桌面 3-4 列）
                const UtenSectionHeader(title: '报销明细'),
                const SizedBox(height: UtenSpacing.s8),
                // 单张报销单的明细行，天然 1-20 条（受单据本身约束），无需分页。
                UtenResponsiveGrid(
                  itemCount: claim.items.length,
                  spacing: UtenSpacing.s12,
                  itemBuilder: (context, i, _) =>
                      _buildItemRow(theme, claim.items[i]),
                ),
                const SizedBox(height: UtenSpacing.s16),

                // 合计
                UtenCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      UtenInfoRow(
                        label: '共 ${claim.items.length} 项',
                        value: '¥ ${claim.totalAmount.toStringAsFixed(2)}',
                        isImportant: true,
                        showDivider: false,
                      ),
                    ],
                  ),
                ),

                // 附件 / 发票
                const SizedBox(height: UtenSpacing.s16),
                AttachmentSection(
                  ownerType: 'EXPENSE_CLAIM',
                  ownerId: claim.id,
                  attachments: claim.attachments,
                  ownerCanUpload:
                      claim.status == ExpenseClaimStatus.draft ||
                      claim.status == ExpenseClaimStatus.rejected,
                  ownerCanDelete:
                      claim.status == ExpenseClaimStatus.draft ||
                      claim.status == ExpenseClaimStatus.rejected,
                  onChanged: () =>
                      ref.invalidate(expenseDetailProvider(claim.id)),
                ),
              ],
            ),
          ),
        ),

        // 底部操作栏
        if (canSubmit || canWithdraw || canDelete)
          UtenBottomActionBar(
            child: Row(
              children: [
                if (canDelete) ...[
                  UtenActionButton(
                    type: UtenActionButtonType.ghost,
                    icon: Icons.delete_outline_rounded,
                    label: const Text('删除'),
                    loadingLabel: const Text('删除中…'),
                    onAction: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('删除报销草稿？'),
                          content: const Text('删除后无法恢复，请确认该草稿不再需要。'),
                          actionsAlignment: MainAxisAlignment.center,
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, true),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true || !context.mounted) return;
                      try {
                        await deleteExpense(ref, claim.id);
                        if (context.mounted) {
                          context.appSuccess('已删除');
                          context.go(RouteName.expense);
                        }
                      } catch (error) {
                        if (context.mounted) {
                          context.appError('删除失败：$error');
                        }
                      }
                    },
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: canSubmit
                      ? UtenActionButton(
                          icon: Icons.send_rounded,
                          isExpanded: true,
                          label: const Text('提交审批'),
                          loadingLabel: const Text('提交中…'),
                          onAction: () async {
                            try {
                              await submitExpense(ref, claim.id);
                              if (context.mounted) {
                                context.appSuccess('已提交，等待审批');
                              }
                            } catch (error) {
                              if (context.mounted) {
                                context.appError('提交失败：$error');
                              }
                            }
                          },
                        )
                      : UtenActionButton(
                          type: UtenActionButtonType.ghost,
                          icon: Icons.undo_rounded,
                          isExpanded: true,
                          label: const Text('撤回'),
                          loadingLabel: const Text('撤回中…'),
                          onAction: () async {
                            try {
                              await withdrawExpense(ref, claim.id);
                              if (context.mounted) {
                                context.appSuccess('已撤回');
                              }
                            } catch (error) {
                              if (context.mounted) {
                                context.appError('撤回失败：$error');
                              }
                            }
                          },
                        ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildHero(ThemeData theme) {
    return UtenCard(
      padding: const EdgeInsets.all(UtenSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
              UtenStatusBadge(
                label: claim.status.label,
                type: _statusBadgeType(claim.status),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '¥',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                claim.totalAmount.toStringAsFixed(2),
                style: theme.textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: UtenColors.primary,
                  height: 1,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '共 ${claim.items.length} 项明细',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRemark(
    ThemeData theme,
    String title,
    String content,
    Color bg, {
    bool isWarning = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(
          color: isWarning
              ? UtenColors.error.withValues(alpha: 0.3)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isWarning
                ? Icons.warning_amber_rounded
                : Icons.info_outline_rounded,
            size: 16,
            color: isWarning
                ? UtenColors.error
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: isWarning
                        ? UtenColors.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(content, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemRow(ThemeData theme, ExpenseItem item) {
    // 明细小卡：UtenCard 无阴影变体（radius 14 + 细边框）
    return UtenCard(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: item.category.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              item.category.icon,
              color: item.category.color,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.category.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (item.description != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      item.description!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _fmt(item.date),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Text(
            '¥ ${item.amount.toStringAsFixed(2)}',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: UtenColors.primary,
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(DateTime? d) {
    if (d == null) return '—';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  UtenStatusBadgeType _statusBadgeType(ExpenseClaimStatus s) => switch (s) {
    ExpenseClaimStatus.draft => UtenStatusBadgeType.neutral,
    ExpenseClaimStatus.submitted => UtenStatusBadgeType.info,
    ExpenseClaimStatus.reviewing => UtenStatusBadgeType.warning,
    ExpenseClaimStatus.approved => UtenStatusBadgeType.accent,
    ExpenseClaimStatus.rejected => UtenStatusBadgeType.danger,
    ExpenseClaimStatus.paid => UtenStatusBadgeType.success,
  };
}
