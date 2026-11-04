import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_claim_event.dart';
import 'package:uten_imp/features/expense/providers/expense_action_eligibility.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

ExpenseActionEligibility access(
  Set<String> permissions, {
  bool ready = true,
  bool readOnly = false,
  String? employee = 'reviewer',
  bool superAdmin = false,
}) => ExpenseActionEligibility(
  SensitiveReadBoundary(
    identity: ready
        ? AuthenticatedScope(userId: 'user', readOnly: readOnly)
        : null,
    api: ApiClient(Dio()),
    permissions: permissions,
    superAdmin: superAdmin,
  ),
  employee,
);

ExpenseClaim claim(
  ExpenseClaimStatus status, {
  String applicant = 'applicant',
  String? approvedBy,
  ExpenseApprovalStage? stage,
  bool? canApprove,
  bool? serverCanPay,
  int round = 0,
  List<ExpenseClaimEvent> events = const [],
}) => ExpenseClaim(
  id: 'claim',
  claimNo: 'BX1',
  applicantId: applicant,
  applicantName: '申请人',
  title: '差旅',
  items: const [],
  totalAmount: 100,
  status: status,
  createdAt: DateTime(2026, 10, 31),
  approvedBy: approvedBy,
  approvalStage: stage,
  canApprove: canApprove,
  canPay: serverCanPay,
  approvalRound: round,
  events: events,
);

void main() {
  test(
    'staged payment requires server clearance and the current payment grant',
    () {
      final denied = claim(
        ExpenseClaimStatus.approved,
        serverCanPay: false,
        round: 1,
      );
      expect(access({Perm.expensePay}).canPayClaim(denied), isFalse);
      final cleared = claim(
        ExpenseClaimStatus.approved,
        serverCanPay: true,
        round: 1,
      );
      expect(access({Perm.expensePay}).canPayClaim(cleared), isTrue);
      expect(access({Perm.expenseView}).canPayClaim(cleared), isFalse);
      expect(
        access({Perm.expensePay}, readOnly: true).canPayClaim(cleared),
        isFalse,
      );
      expect(
        access({
          Perm.expensePay,
        }).canPayClaim(claim(ExpenseClaimStatus.approved, round: 1)),
        isFalse,
      );
      expect(
        access({Perm.expensePay}).canPayClaim(
          claim(
            ExpenseClaimStatus.approved,
            events: [
              ExpenseClaimEvent(
                type: ExpenseClaimEventType.stageApproved,
                actorName: '同名员工',
                occurredAt: DateTime(2026, 11, 3),
                approvalStage: 'FINANCE_INITIAL',
              ),
            ],
          ),
        ),
        isFalse,
      );
      expect(
        access({
          Perm.expensePay,
        }).canPayClaim(claim(ExpenseClaimStatus.approved)),
        isTrue,
      );
    },
  );

  test('审批预览必须已解析非只读身份、明确审批权、有效待审且非本人', () {
    final pending = claim(ExpenseClaimStatus.submitted);
    expect(access({Perm.expenseView}).canReviewClaim(pending), isFalse);
    expect(
      access({Perm.expenseView}, superAdmin: true).canReviewClaim(pending),
      isFalse,
    );
    expect(
      access({Perm.expenseApprove}, ready: false).canReviewClaim(pending),
      isFalse,
    );
    expect(
      access({Perm.expenseApprove}, employee: null).canReviewClaim(pending),
      isFalse,
    );
    expect(
      access({Perm.expenseApprove}, readOnly: true).canReviewClaim(pending),
      isFalse,
    );
    final reviewer = access({Perm.expenseApprove});
    expect(reviewer.canReviewClaim(pending), isTrue);
    expect(
      reviewer.canReviewClaim(claim(ExpenseClaimStatus.reviewing)),
      isTrue,
    );
    expect(
      reviewer.canReviewClaim(
        claim(ExpenseClaimStatus.submitted, applicant: 'reviewer'),
      ),
      isFalse,
    );
    for (final status in [
      ExpenseClaimStatus.draft,
      ExpenseClaimStatus.approved,
      ExpenseClaimStatus.rejected,
      ExpenseClaimStatus.paid,
    ]) {
      expect(reviewer.canReviewClaim(claim(status)), isFalse);
    }
    expect(reviewer.canReviewClaim(null), isFalse);
  });

  test(
    'new stages require their precise current grant and server row eligibility',
    () {
      final finance = claim(
        ExpenseClaimStatus.reviewing,
        stage: ExpenseApprovalStage.financeInitial,
        canApprove: true,
      );
      expect(access({Perm.expenseApprove}).canReviewClaim(finance), isFalse);
      expect(
        access({Perm.expenseApproveDepartment}).canReviewClaim(finance),
        isFalse,
      );
      expect(
        access({Perm.expenseApproveFinanceInitial}).canReviewClaim(finance),
        isTrue,
      );
      expect(
        access({Perm.expenseApproveFinanceInitial}).canReviewClaim(
          claim(
            ExpenseClaimStatus.reviewing,
            stage: ExpenseApprovalStage.financeInitial,
            canApprove: false,
          ),
        ),
        isFalse,
      );
      final department = claim(
        ExpenseClaimStatus.submitted,
        stage: ExpenseApprovalStage.department,
        canApprove: true,
      );
      expect(
        access({
          Perm.expenseApproveDepartment,
        }).requiresVerifiedInvoices(department),
        isFalse,
      );
      expect(
        access({
          Perm.expenseApproveDepartment,
          Perm.attachmentView,
          Perm.attachmentDownload,
        }).canVerifyInvoice(department),
        isFalse,
      );
    },
  );

  test('原件查看下载只限制通过，不取消原有驳回资格', () {
    final pending = claim(ExpenseClaimStatus.submitted);
    expect(access({Perm.expenseApprove}).canReviewClaim(pending), isTrue);
    expect(access({Perm.expenseApprove}).canInspectClaim(pending), isFalse);
    expect(
      access({
        Perm.expenseApprove,
        Perm.attachmentView,
        Perm.attachmentDownload,
      }).canInspectClaim(pending),
      isTrue,
    );
  });

  test('付款保留独立权和申请人、审批人回避，不借用审批资格', () {
    final approved = claim(ExpenseClaimStatus.approved);
    expect(access({Perm.expenseApprove}).canPayClaim(approved), isFalse);
    final cashier = access({Perm.expensePay});
    expect(cashier.canPayClaim(approved), isTrue);
    expect(
      cashier.canReviewClaim(claim(ExpenseClaimStatus.submitted)),
      isFalse,
    );
    expect(cashier.canPayClaim(claim(ExpenseClaimStatus.submitted)), isFalse);
    expect(
      cashier.canPayClaim(
        claim(ExpenseClaimStatus.approved, applicant: 'reviewer'),
      ),
      isFalse,
    );
    expect(
      cashier.canPayClaim(
        claim(ExpenseClaimStatus.approved, approvedBy: 'reviewer'),
      ),
      isFalse,
    );
    expect(
      access({Perm.expensePay}, readOnly: true).canPayClaim(approved),
      isFalse,
    );
  });
}
