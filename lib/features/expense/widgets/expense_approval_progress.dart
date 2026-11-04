import 'package:flutter/material.dart';

import '../../../components/feedback/uten_workflow_progress.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/expense_claim.dart';
import '../models/expense_claim_event.dart';

const expenseApprovalPreviewNodes = <UtenWorkflowNode>[
  UtenWorkflowNode(title: '填写报销', state: UtenWorkflowNodeState.current),
  UtenWorkflowNode(title: '部门负责人审核'),
  UtenWorkflowNode(title: '财务初核'),
  UtenWorkflowNode(title: '财务复核'),
  UtenWorkflowNode(title: '总经办批准'),
  UtenWorkflowNode(title: '财务付款'),
];

/// Project only facts from the current round; a later stage does not prove that
/// an earlier stage has a recorded signature (especially for imported history).
List<UtenWorkflowNode> expenseApprovalProgressNodes(ExpenseClaim claim) {
  if (claim.abandoned) {
    return const [
      UtenWorkflowNode(title: '已放弃报销', state: UtenWorkflowNodeState.skipped),
    ];
  }
  if (claim.approvalRoutingStale) {
    return [
      const UtenWorkflowNode(
        title: '待重新提交',
        state: UtenWorkflowNodeState.current,
      ),
      for (final stage in ExpenseApprovalStage.values)
        UtenWorkflowNode(title: stage.label),
      const UtenWorkflowNode(title: '财务付款'),
    ];
  }
  final draft = claim.status == ExpenseClaimStatus.draft;
  final events = claim.events
      .where((event) => event.approvalRound == claim.approvalRound)
      .toList();
  final stagedEvents = events
      .where(
        (event) => ExpenseApprovalStage.fromApi(event.approvalStage) != null,
      )
      .toList();
  final legacy =
      !draft &&
      claim.approvalStage == null &&
      claim.approvalRound == 0 &&
      stagedEvents.isEmpty;
  final paid = claim.status == ExpenseClaimStatus.paid;
  final approved = claim.status == ExpenseClaimStatus.approved;
  if (legacy) {
    return [
      const UtenWorkflowNode(title: '填写报销', state: UtenWorkflowNodeState.done),
      UtenWorkflowNode(
        title: '原审批记录',
        state: claim.status == ExpenseClaimStatus.rejected
            ? UtenWorkflowNodeState.rejected
            : (approved || paid)
            ? UtenWorkflowNodeState.done
            : UtenWorkflowNodeState.current,
        details: claim.status == ExpenseClaimStatus.rejected
            ? claim.rejectReason
            : claim.approvedByName,
      ),
      UtenWorkflowNode(
        title: '财务付款',
        state: paid
            ? UtenWorkflowNodeState.done
            : approved
            ? UtenWorkflowNodeState.current
            : UtenWorkflowNodeState.pending,
        details: paid ? claim.paidByName : null,
      ),
    ];
  }
  final rejected = claim.status == ExpenseClaimStatus.rejected;
  final rejection = events
      .where((event) => event.type == ExpenseClaimEventType.rejected)
      .lastOrNull;
  final rejectedStage = rejected
      ? ExpenseApprovalStage.fromApi(rejection?.approvalStage) ??
            claim.approvalStage
      : null;
  return [
    UtenWorkflowNode(
      title: '填写报销',
      state: draft ? UtenWorkflowNodeState.current : UtenWorkflowNodeState.done,
      details: draft ? null : claim.applicantName,
    ),
    for (final stage in ExpenseApprovalStage.values)
      _stageNode(
        claim,
        stage,
        draft ? const [] : stagedEvents,
        draft: draft,
        rejected: rejected,
        rejectedStage: rejectedStage,
        rejection: rejection,
      ),
    UtenWorkflowNode(
      title: '财务付款',
      state: paid
          ? UtenWorkflowNodeState.done
          : approved
          ? UtenWorkflowNodeState.current
          : UtenWorkflowNodeState.pending,
      details: paid ? claim.paidByName : null,
    ),
  ];
}

UtenWorkflowNode _stageNode(
  ExpenseClaim claim,
  ExpenseApprovalStage stage,
  List<ExpenseClaimEvent> events, {
  required bool draft,
  required bool rejected,
  required ExpenseApprovalStage? rejectedStage,
  required ExpenseClaimEvent? rejection,
}) {
  final completion = events
      .where(
        (event) =>
            event.approvalStage == stage.apiValue &&
            (event.type == ExpenseClaimEventType.stageApproved ||
                event.type == ExpenseClaimEventType.approved),
      )
      .lastOrNull;
  final isRejected = !draft && rejected && rejectedStage == stage;
  final current =
      !draft &&
      !rejected &&
      (claim.status == ExpenseClaimStatus.submitted ||
          claim.status == ExpenseClaimStatus.reviewing) &&
      claim.approvalStage == stage;
  return UtenWorkflowNode(
    key: ValueKey('expense-approval-progress-${stage.apiValue}'),
    title: stage.label,
    state: isRejected
        ? UtenWorkflowNodeState.rejected
        : current
        ? UtenWorkflowNodeState.current
        : completion != null
        ? UtenWorkflowNodeState.done
        : UtenWorkflowNodeState.pending,
    details: isRejected
        ? rejection?.remark ?? claim.rejectReason
        : completion?.actorName,
  );
}

class ExpenseApprovalProgress extends StatelessWidget {
  const ExpenseApprovalProgress({
    super.key,
    required this.claim,
    this.showHeader = true,
  });
  const ExpenseApprovalProgress.preview({super.key, this.showHeader = true})
    : claim = null;
  final ExpenseClaim? claim;
  final bool showHeader;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (showHeader) ...[
        UtenSectionHeader(
          title: '审批进度',
          info: claim?.approvalRoutingStale == true
              ? '审批设置已调整，请先撤回申请，再重新提交审批。原审批历史保留。'
              : '以当前审批环节和本轮实际操作为准。未记录的历史签批不会补标完成，完整意见可在流转记录中核对。',
        ),
        const SizedBox(height: UtenSpacing.s8),
      ],
      UtenWorkflowProgress(
        nodes: claim == null
            ? expenseApprovalPreviewNodes
            : expenseApprovalProgressNodes(claim!),
      ),
    ],
  );
}
