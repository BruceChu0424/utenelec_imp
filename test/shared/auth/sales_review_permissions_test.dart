import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/sales_review/sales_review_permissions.dart';

void main() {
  test(
    'quote manager and finance stages never substitute each other grants',
    () {
      final manager = SalesReviewPermissions.forQuote(managerReview: true);
      final finance = SalesReviewPermissions.forQuote(managerReview: false);
      expect(manager.observed, {
        Perm.salesQuoteManagerView,
        Perm.salesQuoteManagerConfirm,
        Perm.salesQuoteManagerReject,
        Perm.salesQuoteManagerReverse,
      });
      expect(finance.observed, {
        Perm.salesQuoteFinanceView,
        Perm.salesQuoteFinanceConfirm,
        Perm.salesQuoteFinanceReject,
        Perm.salesQuoteFinanceReverse,
      });
      expect(manager.observed.intersection(finance.observed), isEmpty);
      expect(manager.reject, isNot(manager.confirm));
      expect(manager.reverse, isNot(manager.confirm));
    },
  );

  test(
    'order manager reject-only and reversal remain independent decisions',
    () {
      final manager = SalesReviewPermissions.forOrder(managerReview: true);
      expect(manager.view, Perm.salesOrderManagerView);
      expect(manager.confirm, Perm.salesOrderManagerConfirm);
      expect(manager.reject, Perm.salesOrderManagerReject);
      expect(manager.reverse, Perm.salesOrderManagerReverse);
      expect(manager.observed.length, 4);
      expect(
        manager.observed.intersection(
          SalesReviewPermissions.orderFinance.observed,
        ),
        isEmpty,
      );
    },
  );

  test(
    'order finance retains existing confirmation/rejection and unapproval contract',
    () {
      final finance = SalesReviewPermissions.forOrder(managerReview: false);
      expect(finance.view, Perm.salesOrderFinanceView);
      expect(finance.confirm, Perm.salesOrderFinanceConfirm);
      expect(finance.reject, finance.confirm);
      expect(finance.reverse, Perm.salesOrderReverse);
      expect(finance.observed.length, 3);
    },
  );
}
