// 报销审批详情页（Phase 3）
// 文档：docs/03-页面/报销审批详情页.md · 审批流见 docs/05-架构/全局机制.md §3.3

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/theme/uten_colors.dart';
import '../models/expense_claim.dart';
import '../providers/expense_providers.dart';

class ExpenseApprovalDetailPage extends ConsumerStatefulWidget {
  const ExpenseApprovalDetailPage({super.key, required this.claimId});
  final String claimId;

  @override
  ConsumerState<ExpenseApprovalDetailPage> createState() =>
      _ExpenseApprovalDetailPageState();
}

class _ExpenseApprovalDetailPageState
    extends ConsumerState<ExpenseApprovalDetailPage> {
  final _comment = TextEditingController();
  bool _acting = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  bool get _isMinePending {
    final c = ref.read(expenseDetailProvider(widget.claimId)).valueOrNull;
    return c != null &&
        (c.status == ExpenseClaimStatus.submitted ||
            c.status == ExpenseClaimStatus.reviewing);
  }

  Future<void> _act(bool approve) async {
    setState(() => _acting = true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      setState(() => _acting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(approve ? '已通过（Mock）' : '已驳回（Mock）')),
      );
      ref.invalidate(expenseApprovalListProvider);
      context.go('/expense/approval');
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(expenseDetailProvider(widget.claimId));

    return Scaffold(
      appBar: const UtenAppBar(title: '审批详情', showBackButton: true),
      bottomNavigationBar: _isMinePending
          ? UtenBottomActionBar(
              child: Row(
                children: [
                  UtenButton(
                    type: UtenButtonType.ghost,
                    isLoading: _acting,
                    icon: Icons.close_rounded,
                    onPressed: () => _act(false),
                    child: const Text('驳回'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: UtenButton(
                      isLoading: _acting,
                      isExpanded: true,
                      icon: Icons.check_rounded,
                      onPressed: () => _act(true),
                      child: const Text('通过'),
                    ),
                  ),
                ],
              ),
            )
          : null,
      body: detail.when(
        loading: () => const UtenSkeletonList(itemCount: 4),
        error: (e, _) => UtenEmpty.error(
          message: '加载失败：$e',
          onAction: () =>
              ref.invalidate(expenseDetailProvider(widget.claimId)),
        ),
        data: (claim) {
          if (claim == null) {
            return const UtenEmpty(message: '报销单不存在');
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Hero(claim: claim),
                    const SizedBox(height: 16),
                    const UtenSectionHeader(title: '申请信息'),
                    const SizedBox(height: 8),
                    UtenCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      child: Column(
                        children: [
                          UtenInfoRow(label: '申请人', value: claim.applicantName),
                          UtenInfoRow(label: '标题', value: claim.title, isImportant: true),
                          UtenInfoRow(
                            label: '提交时间',
                            value: _fmt(claim.submittedAt ?? claim.createdAt),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const UtenSectionHeader(title: '报销明细'),
                    const SizedBox(height: 8),
                    UtenCard(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          for (final it in claim.items) ...[
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.receipt_outlined,
                                  color: UtenColors.teal600, size: 20),
                              title: Text('${it.category.label}  ·  ${it.description ?? ''}',
                                  style: Theme.of(context).textTheme.bodyMedium),
                              trailing: Text('¥ ${it.amount.toStringAsFixed(0)}'),
                            ),
                            if (it != claim.items.last)
                              const Divider(height: 1),
                          ],
                          const Divider(),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text('共 ${claim.items.length} 项  合计 ',
                                  style: Theme.of(context).textTheme.bodyMedium),
                              Text('¥ ${claim.totalAmount.toStringAsFixed(0)}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        color:
                                            Theme.of(context).colorScheme.primary,
                                      )),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const UtenSectionHeader(title: '审批轨迹'),
                    const SizedBox(height: 8),
                    UtenCard(
                      child: _ApprovalTimeline(claim: claim),
                    ),
                    if (_isMinePending) ...[
                      const SizedBox(height: 20),
                      const UtenSectionHeader(title: '审批意见'),
                      const SizedBox(height: 8),
                      UtenCard(
                        padding: const EdgeInsets.all(12),
                        child: TextField(
                          controller: _comment,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            hintText: '填写审批意见（驳回必填）',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.claim});
  final ExpenseClaim claim;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [UtenColors.deepGreen, UtenColors.teal600],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UtenStatusBadge(label: claim.status.label, type: _badge(claim.status)),
          const SizedBox(height: 12),
          const Text('报销总额',
              style: TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 4),
          Text('¥ ${claim.totalAmount.toStringAsFixed(2)}',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

class _ApprovalTimeline extends StatelessWidget {
  const _ApprovalTimeline({required this.claim});
  final ExpenseClaim claim;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // mock 轨迹：提交 → 主管 → 财务（当前）
    final nodes = <_TNode>[
      _TNode('提交申请', claim.applicantName, _fmt(claim.submittedAt ?? claim.createdAt), _TState.done),
      const _TNode('主管审批', '部门主管', '同意', _TState.done),
      const _TNode('财务审批', '待审批', '', _TState.pending),
    ];
    return Column(
      children: [
        for (var i = 0; i < nodes.length; i++) ...[
          _TimelineItem(node: nodes[i]),
          if (i != nodes.length - 1)
            Container(
              margin: const EdgeInsets.only(left: 7),
              width: 2,
              height: 22,
              color: theme.colorScheme.outlineVariant,
            ),
        ],
      ],
    );
  }
}

enum _TState { done, pending }

class _TNode {
  const _TNode(this.title, this.actor, this.remark, this.state);
  final String title;
  final String actor;
  final String remark;
  final _TState state;
}

class _TimelineItem extends StatelessWidget {
  const _TimelineItem({required this.node});
  final _TNode node;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = node.state == _TState.done ? UtenColors.teal500 : UtenColors.slate400;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Container(
            width: 12, height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(node.title,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(node.state == _TState.pending ? '待审批' : '${node.actor} · ${node.remark}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
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
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
