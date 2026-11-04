import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_workflow_progress.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_claim_event.dart';
import 'package:uten_imp/features/expense/widgets/expense_approval_progress.dart';

ExpenseClaim _claim(
  ExpenseClaimStatus status, {
  int round = 1,
  ExpenseApprovalStage? stage,
  List<ExpenseClaimEvent> events = const [],
}) => ExpenseClaim(
  id: 'claim',
  claimNo: 'BX1',
  applicantId: 'applicant',
  applicantName: '申请人',
  title: '差旅报销',
  items: const [],
  totalAmount: 12.34,
  status: status,
  createdAt: DateTime(2026, 11, 3),
  approvalRound: round,
  approvalStage: stage,
  events: events,
);

ExpenseClaimEvent _event(
  ExpenseClaimEventType type,
  String stage, {
  int round = 1,
}) => ExpenseClaimEvent(
  type: type,
  actorName: '审核员',
  occurredAt: DateTime(2026, 11, 3),
  approvalStage: stage,
  approvalRound: round,
  remark: '核对凭证',
);

Map<String, UtenWorkflowNodeState> _states(ExpenseClaim claim) => {
  for (final node in expenseApprovalProgressNodes(claim))
    node.title: node.state,
};

void main() {
  test('only recorded decisions in the current round count as complete', () {
    final states = _states(
      _claim(
        ExpenseClaimStatus.reviewing,
        stage: ExpenseApprovalStage.financeReview,
        round: 2,
        events: [
          _event(ExpenseClaimEventType.stageApproved, 'DEPARTMENT'),
          _event(
            ExpenseClaimEventType.stageApproved,
            'FINANCE_INITIAL',
            round: 2,
          ),
        ],
      ),
    );
    expect(states['部门负责人审核'], UtenWorkflowNodeState.pending);
    expect(states['财务初核'], UtenWorkflowNodeState.done);
    expect(states['财务复核'], UtenWorkflowNodeState.current);
    expect(states['总经办批准'], UtenWorkflowNodeState.pending);
    expect(states['财务付款'], UtenWorkflowNodeState.pending);
  });

  test(
    'rejection marks its recorded node without inventing previous approvals',
    () {
      final states = _states(
        _claim(
          ExpenseClaimStatus.rejected,
          stage: ExpenseApprovalStage.financeReview,
          events: [_event(ExpenseClaimEventType.rejected, 'FINANCE_REVIEW')],
        ),
      );
      expect(states['财务复核'], UtenWorkflowNodeState.rejected);
      expect(states['部门负责人审核'], UtenWorkflowNodeState.pending);
      expect(states['财务初核'], UtenWorkflowNodeState.pending);
      expect(states['总经办批准'], UtenWorkflowNodeState.pending);
    },
  );

  test('withdrawn draft clears previous same-round stage completion', () {
    final states = _states(
      _claim(
        ExpenseClaimStatus.draft,
        events: [_event(ExpenseClaimEventType.stageApproved, 'DEPARTMENT')],
      ),
    );
    expect(states['填写报销'], UtenWorkflowNodeState.current);
    expect(states.values.skip(1), everyElement(UtenWorkflowNodeState.pending));
  });

  test(
    'legacy approved records show original approval rather than four signatures',
    () {
      final states = _states(_claim(ExpenseClaimStatus.approved, round: 0));
      expect(states.keys, ['填写报销', '原审批记录', '财务付款']);
      expect(states['原审批记录'], UtenWorkflowNodeState.done);
      expect(states['财务付款'], UtenWorkflowNodeState.current);
    },
  );

  testWidgets(
    'shared strip wraps at narrow width and large text without clipping facts',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(1.8)),
            child: Scaffold(
              body: Padding(
                padding: EdgeInsets.all(16),
                child: UtenWorkflowProgress(
                  nodes: [
                    UtenWorkflowNode(
                      title: '部门负责人审核',
                      state: UtenWorkflowNodeState.done,
                    ),
                    UtenWorkflowNode(
                      title: '财务初核',
                      state: UtenWorkflowNodeState.current,
                      details: '已核对 1200.00 元，原始票据共 12 张',
                    ),
                    UtenWorkflowNode(title: '财务复核'),
                    UtenWorkflowNode(title: '总经办批准'),
                    UtenWorkflowNode(title: '财务付款'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('已核对 1200.00 元，原始票据共 12 张'), findsOneWidget);
    },
  );
}
