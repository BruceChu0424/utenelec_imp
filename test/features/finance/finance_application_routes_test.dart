import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/config/finance_application_routes.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test('all original six fresh entries use their current owning workflow', () {
    expect(financeApplicationCreateLocation('TRAVEL_APPLICATION'), '/applications/new?kind=TRAVEL');
    expect(financeApplicationCreateLocation('TRAVEL_REIMBURSEMENT'), '/expense/new?kind=TRAVEL&applicationKind=TRAVEL_REIMBURSEMENT');
    expect(financeApplicationCreateLocation('REIMBURSEMENT'), '/expense/new?kind=GENERAL&applicationKind=REIMBURSEMENT');
    expect(financeApplicationCreateLocation('PAYMENT_APPLICATION'), '/applications/new?kind=PAYMENT');
    expect(financeApplicationCreateLocation('PREPAYMENT_APPLICATION'), '/applications/new?kind=PREPAYMENT');
    expect(financeApplicationCreateLocation('PAYROLL_PAYMENT'), '/finance/applications/new?kind=PAYROLL_PAYMENT');
    expect(financeApplicationCreateLocation('UNKNOWN'), isNull);
  });
  test('old local recovery and unknown original requests are not silently rerouted', () {
    for(final key in ['resumeDraft','draftId','requestId','createdDocId']) {
      expect(redirectFreshFinanceApplication(Uri.parse('/finance/applications/new?kind=PAYMENT_APPLICATION&$key=original')), isNull);
    }
    expect(redirectFreshFinanceApplication(Uri.parse('/finance/applications/new?kind=PAYROLL_PAYMENT')),isNull);
    expect(redirectFreshFinanceApplication(Uri.parse('/finance/applications/new?kind=PAYMENT_APPLICATION')),'/applications/new?kind=PAYMENT');
  });
  test('original finance apply authority cannot invent new employee application authority', () {
    expect(canCreateFinanceApplicationKind('PAYMENT_APPLICATION',{Perm.financeApplicationApply}),isFalse);
    expect(canCreateFinanceApplicationKind('PAYMENT_APPLICATION',{Perm.applicationApplyPayment}),isTrue);
    expect(canCreateFinanceApplicationKind('PREPAYMENT_APPLICATION',{Perm.applicationApplyPayment}),isFalse);
    expect(canCreateFinanceApplicationKind('PREPAYMENT_APPLICATION',{Perm.applicationApply}),isTrue);
    expect(canCreateFinanceApplicationKind('TRAVEL_REIMBURSEMENT',{Perm.expenseApply}),isTrue);
  });
}
