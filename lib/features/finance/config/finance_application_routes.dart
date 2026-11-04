import '../../../shared/auth/permissions.dart';

/// Original six names remain the source index. Fresh work uses its owning
/// application's current workflow; existing IDs and unknown commands stay put.
String? financeApplicationCreateLocation(String kind) => switch (kind) {
  'TRAVEL_APPLICATION' => '/applications/new?kind=TRAVEL',
  'TRAVEL_REIMBURSEMENT' =>
    '/expense/new?kind=TRAVEL&applicationKind=TRAVEL_REIMBURSEMENT',
  'REIMBURSEMENT' => '/expense/new?kind=GENERAL&applicationKind=REIMBURSEMENT',
  'PAYMENT_APPLICATION' => '/applications/new?kind=PAYMENT',
  'PREPAYMENT_APPLICATION' => '/applications/new?kind=PREPAYMENT',
  'PAYROLL_PAYMENT' => '/finance/applications/new?kind=PAYROLL_PAYMENT',
  _ => null,
};

bool canCreateFinanceApplicationKind(String kind, Set<String> permissions) {
  bool application(String specific) =>
      permissions.contains(Perm.applicationApply) ||
      permissions.contains(specific);
  return switch (kind) {
    'TRAVEL_APPLICATION' => application(Perm.applicationApplyTravel),
    'PAYMENT_APPLICATION' => application(Perm.applicationApplyPayment),
    'PREPAYMENT_APPLICATION' => application(Perm.applicationApplyPrepayment),
    'REIMBURSEMENT' ||
    'TRAVEL_REIMBURSEMENT' => permissions.contains(Perm.expenseApply),
    'PAYROLL_PAYMENT' => permissions.contains(Perm.payrollGenerate),
    _ => false,
  };
}

String? redirectFreshFinanceApplication(Uri uri) {
  if (uri.queryParameters.keys.any(
    const {'resumeDraft', 'draftId', 'requestId', 'createdDocId'}.contains,
  )) {
    return null;
  }
  final kind = uri.queryParameters['kind'];
  if (kind == null || kind.isEmpty) return '/finance/applications';
  if (kind == 'PAYROLL_PAYMENT') return null;
  return financeApplicationCreateLocation(kind);
}
