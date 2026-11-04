import 'package:flutter/widgets.dart';
import '../../../components/feedback/uten_workflow_progress.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/business_application.dart';

class BusinessApplicationProgress extends StatelessWidget {
  const BusinessApplicationProgress({super.key, required this.application});
  final BusinessApplication application;
  @override
  Widget build(BuildContext context) {
    if (application.status == 'CANCELLED') {
      return const UtenWorkflowProgress(
        nodes: [
          UtenWorkflowNode(title: '已作废', state: UtenWorkflowNodeState.skipped),
        ],
      );
    }
    final events = application.events
        .where((event) => event.round == application.round)
        .toList();
    final rejection = events
        .where((event) => event.action == 'REJECTED')
        .lastOrNull;
    return UtenWorkflowProgress(
      nodes: [
        UtenWorkflowNode(
          title: application.approvalRoutingStale ? '待重新提交' : '填写申请',
          state:
              application.approvalRoutingStale ||
                  const {'DRAFT', 'REJECTED'}.contains(application.status)
              ? UtenWorkflowNodeState.current
              : events.any((event) => event.action == 'SUBMITTED')
              ? UtenWorkflowNodeState.done
              : UtenWorkflowNodeState.pending,
        ),
        for (final stage
            in businessApplicationWorkflowStages[application.kind] ??
                const <String>[])
          _node(stage, events, rejection),
        if (application.kind == 'PREPAYMENT')
          UtenWorkflowNode(
            title: '预付账务关联',
            state: application.status == 'PAID'
                ? application.postingStatus == 'POSTED'
                      ? UtenWorkflowNodeState.done
                      : UtenWorkflowNodeState.current
                : UtenWorkflowNodeState.pending,
            details:
                application.status == 'PAID' &&
                    application.postingStatus == 'PENDING'
                ? '待财务入账'
                : null,
          ),
      ],
    );
  }

  UtenWorkflowNode _node(
    String stage,
    List<BusinessApplicationEvent> events,
    BusinessApplicationEvent? rejection,
  ) {
    var state = UtenWorkflowNodeState.pending;
    String? details;
    if (application.status != 'DRAFT' && !application.approvalRoutingStale) {
      final completed = events
          .where(
            (event) =>
                event.stage == stage &&
                const {'APPROVED', 'RECEIVED', 'PAID'}.contains(event.action),
          )
          .lastOrNull;
      if (completed != null) {
        state = UtenWorkflowNodeState.done;
        details =
            '${completed.actorName}  ${ChinaDateTime.formatDateTime(completed.occurredAt)}';
      }
      if (application.status == 'REJECTED' && rejection?.stage == stage) {
        state = UtenWorkflowNodeState.rejected;
        details = rejection!.remark;
      } else if (application.approvalStage == stage &&
          const {
            'SUBMITTED',
            'REVIEWING',
            'APPROVED',
          }.contains(application.status)) {
        state = UtenWorkflowNodeState.current;
        details = null;
      }
    }
    return UtenWorkflowNode(
      title: businessApplicationStageLabel(stage, kind: application.kind),
      state: state,
      details: details,
    );
  }
}
