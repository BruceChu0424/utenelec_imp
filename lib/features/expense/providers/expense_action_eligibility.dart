import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../models/expense_claim.dart';

/// UI preview only; the server retains its independent row, evidence and transaction guards.
final class ExpenseActionEligibility {
  const ExpenseActionEligibility(this.boundary, this.employeeId);

  final SensitiveReadBoundary boundary;
  final String? employeeId;

  Object get owner => (boundary.identity, boundary.api, employeeId);
  bool get resolved =>
      boundary.identity != null &&
      !boundary.identity!.readOnly &&
      employeeId != null &&
      employeeId!.trim().isNotEmpty;
  bool get canReview =>
      resolved &&
      Perm.expenseApprovalPermissions.any(boundary.permissions.contains);
  bool get canPay => resolved && boundary.permissions.contains(Perm.expensePay);

  bool _hasStagePermission(ExpenseClaim claim) => boundary.permissions.contains(
    switch (claim.approvalStage) {
      ExpenseApprovalStage.department => Perm.expenseApproveDepartment,
      ExpenseApprovalStage.financeInitial => Perm.expenseApproveFinanceInitial,
      ExpenseApprovalStage.financeReview => Perm.expenseApproveFinanceReview,
      ExpenseApprovalStage.executive => Perm.expenseApproveExecutive,
      null => Perm.expenseApprove,
    },
  );

  bool canReviewClaim(ExpenseClaim? claim) =>
      canReview &&
      claim != null &&
      (claim.financialApplication == null || claim.canApprove != null) &&
      claim.id.isNotEmpty &&
      claim.applicantId.isNotEmpty &&
      claim.applicantId != employeeId &&
      _hasStagePermission(claim) &&
      (claim.canApprove ??
          (claim.approvalStage == null &&
              boundary.permissions.contains(Perm.expenseApprove))) &&
      (claim.status == ExpenseClaimStatus.submitted ||
          claim.status == ExpenseClaimStatus.reviewing);

  bool canInspectClaim(ExpenseClaim? claim) =>
      canReviewClaim(claim) &&
      boundary.permissions.contains(Perm.attachmentView) &&
      boundary.permissions.contains(Perm.attachmentDownload);

  bool requiresVerifiedInvoices(ExpenseClaim claim) =>
      claim.approvalStage != ExpenseApprovalStage.department;

  bool canVerifyInvoice(ExpenseClaim? claim) =>
      canInspectClaim(claim) &&
      (claim!.approvalStage == null ||
          claim.approvalStage == ExpenseApprovalStage.financeInitial ||
          claim.approvalStage == ExpenseApprovalStage.financeReview);

  bool _legacyPaymentClaim(ExpenseClaim claim) =>
      claim.approvalRound == 0 &&
      claim.approvalStage == null &&
      !claim.events.any(
        (event) =>
            event.approvalRound > 0 ||
            (event.approvalStage?.trim().isNotEmpty ?? false),
      );

  /// Payment has its own authority and separation-of-duties contract.
  bool canPayClaim(ExpenseClaim? claim) =>
      canPay &&
      claim != null &&
      (claim.financialApplication == null || claim.canPay != null) &&
      claim.status == ExpenseClaimStatus.approved &&
      claim.applicantId.isNotEmpty &&
      claim.applicantId != employeeId &&
      claim.approvedBy != employeeId &&
      (claim.canPay ?? _legacyPaymentClaim(claim));

  @override
  bool operator ==(Object other) =>
      other is ExpenseActionEligibility &&
      boundary == other.boundary &&
      employeeId == other.employeeId;

  @override
  int get hashCode => Object.hash(boundary, employeeId);
}

final expenseActionEligibilityProvider = Provider<ExpenseActionEligibility>(
  (ref) => ExpenseActionEligibility(
    ref.watch(sensitiveReadBoundaryProvider),
    ref.watch(sessionProvider.select((session) => session.user?.employeeId)),
  ),
);
