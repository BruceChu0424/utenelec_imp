import 'native_facet_routes.dart';

String _apiPath(String path) =>
    path.startsWith('/api/') ? path.substring(4) : path;

/// This POST only projects existing values. Definition creation, usage and
/// cell writes have separate endpoints and must retain commit protection.
bool isPlatformValuesRead(String path) =>
    _platformValuesRead.hasMatch(_apiPath(path));

bool isReadOnlyPost(String path) =>
    isNativeFacetPath(path) ||
    isPlatformValuesRead(path) ||
    isSearchReadPost(path) ||
    _materialAggregatePreview.hasMatch(_apiPath(Uri.parse(path).path)) ||
    _materialOperationVerify.hasMatch(_apiPath(Uri.parse(path).path)) ||
    const {
      '/sales/orders/delivery-preview',
      '/finance/statement-documents/metadata',
      '/finance/statement-documents/preview',
      '/finance/statement-documents/settlement-preview',
      '/finance/statement-documents/reviews/query',
    }.contains(_apiPath(Uri.parse(path).path));

/// Reviewed query handlers only. Body-carried contact/bank terms remain out of
/// URLs, while searches retain the same read lifecycle as their GET versions.
bool isSearchReadPost(String path) =>
    isGoodsSearchRead(path) ||
    const {
      '/master/clients/search',
      '/master/clients/search-context',
      '/master/suppliers/search',
      '/master/suppliers/search-context',
      '/master/accounts/search',
      '/business-references/clients/search',
      '/business-references/clients/search-context',
      '/business-references/suppliers/search',
      '/business-references/suppliers/search-context',
      '/finance/reports/ar-ap/overview/search',
      '/quality/pending-disposals/query',
      '/production/daily-reports/draft-claims/query',
      '/security/blacklist/search',
      '/master/clients/access-candidates/query',
      '/admin/data-handovers/candidates/query',
    }.contains(_apiPath(path));

/// Large authorized category scopes travel in a JSON body rather than an URL.
/// Match only these pure reads; neighboring goods commands remain mutations.
bool isGoodsSearchRead(String path) => const {
  '/master/goods/summaries',
  '/master/clients/summaries',
  '/master/suppliers/summaries',
  '/master/moulds/summaries',
  '/master/colors/summaries',
  '/master/units/summaries',
  '/master/currencies/summaries',
  '/master/accounts/summaries',
  '/master/reference-methods/settlement-admin/summaries',
  '/business-references/clients/summaries',
  '/business-references/suppliers/summaries',
  '/business-references/goods/summaries',
  '/master/goods/search',
  '/master/goods/search-category-ids',
  '/master/goods/facets',
  '/master/goods/facet-values',
  '/business-references/goods/search',
  '/business-references/goods/search-category-ids',
  '/business-references/goods/facets',
  '/business-references/goods/facet-values',
}.contains(_apiPath(path));

/// A failed sign-in may leave an unused server session, but has no document
/// commit to reconcile. Do not replay it or persist its credentials. Refresh,
/// password changes and all business mutations keep their existing fences.
bool isEphemeralSignIn(String path) => _apiPath(path) == '/auth/login';

/// These receipts only change read/popup presentation state. A failed receipt
/// may leave a notification unread or visible again after reload; it cannot
/// lose business input or complete a task. This is NOT permission to retry it.
/// Every other mutation, including task completion, keeps the unknown-commit
/// fence. Match whole paths so new actions cannot silently inherit this rule.
bool isNoticePresentationReceipt(String path) {
  final local = _apiPath(path);
  return const {
        '/notices/read-all',
        '/notices/read-by-route',
        '/notices/read-by-source',
      }.contains(local) ||
      _noticePresentationReceipt.hasMatch(local);
}

final _platformValuesRead = RegExp(
  r'^/platform-columns/[a-z][a-z0-9_]*/values:batch$',
);

final _noticePresentationReceipt = RegExp(
  r'^/notices/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/(read|popup-ack)$',
);

// Audited read-only services; adjacent submit/cancel routes remain writes.
const _semanticUuid =
    r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
final _materialAggregatePreview = RegExp(
  '^/production/material-analyses/$_semanticUuid/aggregate-orders/preview\$',
);
final _materialOperationVerify = RegExp(
  '^/finance/material-statements/operations/$_semanticUuid/verify\$',
);
