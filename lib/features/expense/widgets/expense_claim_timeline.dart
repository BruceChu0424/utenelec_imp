// 报销单审批轨迹（V608）：事件表真轨迹（操作人姓名快照 + 备注），
// 事件为空时回退到由单据时间戳合成（兼容 V608 之前的老数据/测试夹具）。
// 供报销详情页与审批详情页共用。

import 'package:flutter/material.dart';

import '../../../core/theme/uten_colors.dart';
import '../models/expense_claim.dart';
import '../models/expense_claim_event.dart';

class ExpenseClaimTimeline extends StatelessWidget {
  const ExpenseClaimTimeline({super.key, required this.claim});

  final ExpenseClaim claim;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nodes = claim.events.isEmpty
        ? _synthesizedNodes(claim)
        : [
            for (final event in claim.events)
              _Node(
                event.type.label +
                    (event.remark == null ? '' : ' · ${event.remark}'),
                event.actorName,
                _fmt(event.occurredAt),
                event.type == ExpenseClaimEventType.rejected
                    ? _TState.rejected
                    : _TState.done,
              ),
          ];
    // 当前所处环节的待办节点（数据来自单据状态，而非事件表）。
    _appendPendingNode(nodes, claim);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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

  /// V608 之前的老单（无事件行）：按时间戳合成，操作人取单据回显姓名。
  List<_Node> _synthesizedNodes(ExpenseClaim claim) {
    return [
      _Node('创建报销单', claim.applicantName, _fmt(claim.createdAt), _TState.done),
      if (claim.submittedAt != null)
        _Node(
          '提交审批',
          claim.applicantName,
          _fmt(claim.submittedAt!),
          _TState.done,
        ),
      if (claim.approvedAt != null)
        _Node(
          '审批通过',
          claim.approvedByName ?? '',
          _fmt(claim.approvedAt!),
          _TState.done,
        ),
      if (claim.status == ExpenseClaimStatus.rejected)
        _Node(
          '审批驳回 · ${claim.rejectReason ?? '未填写原因'}',
          claim.rejectedByName ?? '',
          claim.rejectedAt == null ? '' : _fmt(claim.rejectedAt!),
          _TState.rejected,
        ),
      if (claim.paidAt != null)
        _Node(
          '已登记付款',
          claim.paidByName ?? '',
          _fmt(claim.paidAt!),
          _TState.done,
        ),
    ];
  }

  void _appendPendingNode(List<_Node> nodes, ExpenseClaim claim) {
    switch (claim.status) {
      case ExpenseClaimStatus.draft:
        nodes.add(const _Node('补充凭证后提交审批', '', '', _TState.pending));
        break;
      case ExpenseClaimStatus.rejected:
        nodes.add(const _Node('按驳回原因修订后重新提交', '', '', _TState.pending));
        break;
      case ExpenseClaimStatus.paid:
        break;
      case ExpenseClaimStatus.submitted:
      case ExpenseClaimStatus.reviewing:
        nodes.add(const _Node('等待审批', '', '', _TState.pending));
        break;
      case ExpenseClaimStatus.approved:
        nodes.add(const _Node('等待财务登记付款', '', '', _TState.pending));
        break;
    }
  }
}

enum _TState { done, pending, rejected }

class _Node {
  const _Node(this.title, this.actor, this.time, this.state);
  final String title;
  final String actor;
  final String time;
  final _TState state;
}

class _TimelineItem extends StatelessWidget {
  const _TimelineItem({required this.node});
  final _Node node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (node.state) {
      _TState.done => UtenColors.teal500,
      _TState.pending => UtenColors.slate400,
      _TState.rejected => UtenColors.error,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                node.title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                node.state == _TState.pending
                    ? '待处理'
                    : [
                        node.actor,
                        node.time,
                      ].where((value) => value.isNotEmpty).join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _fmt(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
