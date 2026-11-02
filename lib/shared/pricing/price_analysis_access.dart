import '../auth/commercial_price_visibility.dart';
import '../auth/permissions.dart';

/// Price history/analysis never grants access to its source prices.
const priceAnalysisKinds = ['PURCHASE', 'SUBCONTRACT', 'SALES'];

bool canAnalyzePriceKind(Set<String> grants, bool superAdmin, String kind) {
  if (!priceAnalysisKinds.contains(kind)) return false;
  if (superAdmin) return true;
  if (!grants.containsAll({Perm.goodsView, Perm.goodsPriceAnalysisView})) {
    return false;
  }
  final prefix = kind.toLowerCase();
  final source =
      grants.contains('${prefix}_order:view') ||
      (kind != 'SALES' && grants.contains(Perm.financeOrderApprovalView));
  return source && canViewCommercialPrice(grants, '${prefix}_order:price:view');
}

bool canReadPriceHistoryKind(
  Set<String> grants,
  bool superAdmin,
  String kind,
) =>
    canAnalyzePriceKind(grants, superAdmin, kind) ||
    (kind == 'SALES' &&
        grants.containsAll({
          Perm.goodsView,
          Perm.goodsPriceAnalysisView,
          Perm.salesQuoteFinanceView,
        }));

List<String> readablePriceHistoryKinds(Set<String> grants, bool superAdmin) => [
  for (final kind in priceAnalysisKinds)
    if (canReadPriceHistoryKind(grants, superAdmin, kind)) kind,
];

bool canOpenPriceAnalysis(Set<String> grants, bool superAdmin) =>
    readablePriceHistoryKinds(grants, superAdmin).isNotEmpty;
