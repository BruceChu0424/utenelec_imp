import '../auth/permissions.dart';

/// Stage-specific permission identities for the shared sales review renderers.
/// These do not grant an action: the caller still checks live actor, native
/// capabilities, document state and the same reviewed lease before dispatch.
enum SalesReviewPermissions {
  quoteFinance(
    view: Perm.salesQuoteFinanceView,
    confirm: Perm.salesQuoteFinanceConfirm,
    reject: Perm.salesQuoteFinanceReject,
    reverse: Perm.salesQuoteFinanceReverse,
  ),
  quoteManager(
    view: Perm.salesQuoteManagerView,
    confirm: Perm.salesQuoteManagerConfirm,
    reject: Perm.salesQuoteManagerReject,
    reverse: Perm.salesQuoteManagerReverse,
  ),
  orderFinance(
    view: Perm.salesOrderFinanceView,
    confirm: Perm.salesOrderFinanceConfirm,
    // Existing order-finance confirmation authority also owns finance rejection.
    reject: Perm.salesOrderFinanceConfirm,
    reverse: Perm.salesOrderReverse,
  ),
  orderManager(
    view: Perm.salesOrderManagerView,
    confirm: Perm.salesOrderManagerConfirm,
    reject: Perm.salesOrderManagerReject,
    reverse: Perm.salesOrderManagerReverse,
  );

  const SalesReviewPermissions({
    required this.view,
    required this.confirm,
    required this.reject,
    required this.reverse,
  });

  final String view, confirm, reject, reverse;

  Set<String> get observed => {view, confirm, reject, reverse};

  static SalesReviewPermissions forQuote({required bool managerReview}) =>
      managerReview ? quoteManager : quoteFinance;
  static SalesReviewPermissions forOrder({required bool managerReview}) =>
      managerReview ? orderManager : orderFinance;
}
